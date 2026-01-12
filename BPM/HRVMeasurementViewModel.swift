//
//  HRVMeasurementViewModel.swift
//  BPM
//
//  Created for HRV measurement feature
//

import Foundation
import Combine
import UIKit
import AudioToolbox
import AVFoundation

enum HRVMeasurementState: Equatable {
    case idle
    case countingDown
    case completed
    case error(String) // Error state with message
}

final class HRVMeasurementViewModel: ObservableObject {
    @Published var state: HRVMeasurementState = .idle
    @Published var remainingTime: TimeInterval = 120.0 // 2 minutes
    @Published var hrvValue: Double? // RMSSD value in milliseconds
    @Published var avgHeartRate: Int?
    @Published var minHeartRate: Int?
    @Published var maxHeartRate: Int?
    @Published var currentBPM: Int?
    
    private var timer: Timer?
    private var heartRateSampleTimer: Timer?
    private var liveHeartRateTimer: Timer? // Timer for live BPM updates when not measuring
    private var heartRateSamples: [Int] = []
    private var rrIntervalsDuringMeasurement: [Double] = [] // RR intervals collected during measurement
    private var measurementStartRRIndex: Int = 0 // Index in bluetooth manager's RR intervals array when measurement started
    private var startTime: Date?
    private let measurementDuration: TimeInterval = 120.0 // 2 minutes
    private var audioPlayer: AVAudioPlayer?
    
    var currentHeartRate: (() -> Int?)?
    var getRRIntervals: (() -> [RRInterval])? // Callback to get current RR intervals from bluetooth manager
    var supportsRRIntervals: (() -> Bool)? // Callback to check if device supports RR intervals
    
    var isCompleted: Bool {
        if case .completed = state {
            return true
        }
        return false
    }
    
    var hasError: Bool {
        if case .error = state {
            return true
        }
        return false
    }
    
    var errorMessage: String? {
        if case .error(let message) = state {
            return message
        }
        return nil
    }
    
    func startMeasurement() {
        guard state == .idle || state == .completed || hasError else { return }
        
        // Check if device supports RR intervals
        if let supportsRR = supportsRRIntervals?(), !supportsRR {
            state = .error("Your heart rate monitor does not support RR intervals, which are required for accurate HRV measurement. Please use a compatible chest strap like Polar H10.")
            return
        }
        
        // Stop live updates during measurement (heartRateSampleTimer will handle it)
        liveHeartRateTimer?.invalidate()
        liveHeartRateTimer = nil
        
        // Get current heart rate before resetting (to avoid blanking)
        let currentHeartRateValue = currentHeartRate?()
        
        // Reset state
        state = .countingDown
        remainingTime = measurementDuration
        heartRateSamples.removeAll()
        rrIntervalsDuringMeasurement.removeAll()
        hrvValue = nil
        avgHeartRate = nil
        minHeartRate = nil
        maxHeartRate = nil
        // Preserve current BPM if available, otherwise set to nil
        currentBPM = currentHeartRateValue
        startTime = Date()
        
        // Record the starting index of RR intervals
        if let currentRRIntervals = getRRIntervals?() {
            measurementStartRRIndex = currentRRIntervals.count
        } else {
            measurementStartRRIndex = 0
        }
        
        // Use 5 seconds for simulator, 120 seconds for real device
        #if targetEnvironment(simulator)
        let actualDuration = 5.0
        #else
        let actualDuration = measurementDuration
        #endif
        
        // Start countdown timer
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let startTime = self.startTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    self.remainingTime = max(0, actualDuration - elapsed)
                    
                    // Check if measurement is complete
                    if self.remainingTime <= 0 {
                        self.completeMeasurement()
                    }
                }
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
        
        // Start heart rate sampling timer (every second)
        heartRateSampleTimer?.invalidate()
        heartRateSampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                #if targetEnvironment(simulator)
                // Generate phony heart rate data for simulator (between 60-100 BPM)
                let phonyHeartRate = Int.random(in: 60...100)
                self.currentBPM = phonyHeartRate
                self.heartRateSamples.append(phonyHeartRate)
                
                // Update min/max
                if self.minHeartRate == nil || phonyHeartRate < self.minHeartRate! {
                    self.minHeartRate = phonyHeartRate
                }
                if self.maxHeartRate == nil || phonyHeartRate > self.maxHeartRate! {
                    self.maxHeartRate = phonyHeartRate
                }
                #else
                if let heartRate = self.currentHeartRate?() {
                    self.currentBPM = heartRate
                    self.heartRateSamples.append(heartRate)
                    
                    // Update min/max
                    if heartRate > 0 && (self.minHeartRate == nil || heartRate < self.minHeartRate!) {
                        self.minHeartRate = heartRate
                    }
                    if self.maxHeartRate == nil || heartRate > self.maxHeartRate! {
                        self.maxHeartRate = heartRate
                    }
                }
                #endif
            }
        }
        RunLoop.current.add(heartRateSampleTimer!, forMode: .common)
    }
    
    private func completeMeasurement() {
        timer?.invalidate()
        timer = nil
        heartRateSampleTimer?.invalidate()
        heartRateSampleTimer = nil
        
        // Calculate average heart rate
        if !heartRateSamples.isEmpty {
            let nonZeroSamples = heartRateSamples.filter { $0 > 0 }
            if !nonZeroSamples.isEmpty {
                let total = nonZeroSamples.reduce(0, +)
                avgHeartRate = Int((Double(total) / Double(nonZeroSamples.count)).rounded())
            }
        }
        
        // Collect RR intervals that were received during measurement
        if let allRRIntervals = getRRIntervals?() {
            // Get RR intervals from the start of measurement to now
            let endIndex = allRRIntervals.count
            if endIndex > measurementStartRRIndex {
                let measurementRRIntervals = Array(allRRIntervals[measurementStartRRIndex..<endIndex])
                rrIntervalsDuringMeasurement = measurementRRIntervals.map { $0.value }
            }
        }
        
        // Calculate HRV (RMSSD) from actual RR intervals if available, otherwise fall back to BPM conversion
        if !rrIntervalsDuringMeasurement.isEmpty {
            hrvValue = calculateRMSSDFromRRIntervals(rrIntervalsDuringMeasurement)
        } else {
            // Fallback: calculate from BPM samples (less accurate)
            hrvValue = calculateRMSSD(from: heartRateSamples)
        }
        
        state = .completed
        
        // Play sound and vibrate to alert user (they may have eyes closed)
        playCompletionFeedback()
        
        // Restart live heart rate updates after measurement completes
        startLiveHeartRateUpdates()
    }
    
    private func playCompletionFeedback() {
        // Haptic feedback - success notification (strong vibration)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        
        playCompletionSound()
        
        // Additional haptic feedback for extra emphasis (user may have eyes closed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
            impactGenerator.prepare()
            impactGenerator.impactOccurred()
        }
    }

    private func playCompletionSound() {
        // Configure audio session to play sound even when device is silenced
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AudioServicesPlaySystemSound(1013) // bell
            return
        }

        let soundURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/sms-received1.caf")
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            AudioServicesPlaySystemSound(1013)
        }
    }
    
    private func calculateRMSSDFromRRIntervals(_ rrIntervals: [Double]) -> Double? {
        guard rrIntervals.count >= 2 else { return nil }
        
        // Calculate successive differences between RR intervals
        var differences: [Double] = []
        for i in 1..<rrIntervals.count {
            let diff = rrIntervals[i] - rrIntervals[i-1]
            differences.append(diff * diff) // Square the difference
        }
        
        guard !differences.isEmpty else { return nil }
        
        // Calculate mean of squared differences
        let meanSquaredDiff = differences.reduce(0.0, +) / Double(differences.count)
        
        // RMSSD = sqrt(mean of squared differences)
        return sqrt(meanSquaredDiff)
    }
    
    private func calculateRMSSD(from samples: [Int]) -> Double? {
        guard samples.count >= 2 else { return nil }
        
        // Convert BPM to RR intervals (milliseconds)
        // RR interval = 60000 / BPM
        // This is a fallback method - less accurate than using actual RR intervals
        let rrIntervals = samples.map { 60000.0 / Double($0) }
        
        return calculateRMSSDFromRRIntervals(rrIntervals)
    }
    
    func startLiveHeartRateUpdates() {
        // Start continuous heart rate updates when view appears
        liveHeartRateTimer?.invalidate()
        liveHeartRateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // Only update if not currently measuring (during measurement, heartRateSampleTimer handles it)
                if self.state != .countingDown {
                    if let heartRate = self.currentHeartRate?() {
                        self.currentBPM = heartRate
                    }
                }
            }
        }
        RunLoop.current.add(liveHeartRateTimer!, forMode: .common)
    }
    
    func stopLiveHeartRateUpdates() {
        liveHeartRateTimer?.invalidate()
        liveHeartRateTimer = nil
    }
    
    func reset() {
        timer?.invalidate()
        timer = nil
        heartRateSampleTimer?.invalidate()
        heartRateSampleTimer = nil
        state = .idle
        remainingTime = measurementDuration
        heartRateSamples.removeAll()
        rrIntervalsDuringMeasurement.removeAll()
        hrvValue = nil
        avgHeartRate = nil
        minHeartRate = nil
        maxHeartRate = nil
        currentBPM = nil
        startTime = nil
        measurementStartRRIndex = 0
    }
    
    deinit {
        timer?.invalidate()
        heartRateSampleTimer?.invalidate()
        liveHeartRateTimer?.invalidate()
    }
}
