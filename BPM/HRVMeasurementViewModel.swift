import Foundation
import Combine
import UIKit
import AudioToolbox
import AVFoundation

enum HRVMeasurementState: Equatable {
    case idle
    case countingDown
    case completed
    case error(String)
}

final class HRVMeasurementViewModel: ObservableObject {
    @Published var state: HRVMeasurementState = .idle
    @Published var remainingTime: TimeInterval = 120
    @Published var hrvValue: Double?
    @Published var avgHeartRate: Int?
    @Published var minHeartRate: Int?
    @Published var maxHeartRate: Int?
    @Published var currentBPM: Int?

    private var timer: Timer?
    private var liveHeartRateTimer: Timer?
    private var intervals: [RRInterval] = []
    private var seenIntervals: Set<UUID> = []
    private var heartRateSamples: [HRVHeartRateSample] = []
    private var startTime: Date?
    private var startTicks: TimeInterval?
    private var streamID: UUID?
    private var completedAt: Date?
    private var lastSampleTicks: TimeInterval?
    private let measurementDuration: TimeInterval = 120
    private let ticksProvider: () -> TimeInterval
    private let nowProvider: () -> Date
    private var audioPlayer: AVAudioPlayer?

    var currentHeartRate: (() -> Int?)?
    var getRRIntervals: (() -> [RRInterval])?
    var supportsRRIntervals: (() -> Bool)?
    var currentRRStreamID: (() -> UUID?)?

    init(ticksProvider: @escaping () -> TimeInterval = { MeasurementClock.ticks }, nowProvider: @escaping () -> Date = Date.init) {
        self.ticksProvider = ticksProvider
        self.nowProvider = nowProvider
    }

    var isCompleted: Bool { state == .completed }
    var hasError: Bool { errorMessage != nil }
    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    func startMeasurement() {
        guard state != .countingDown else { return }
        reset()
        guard supportsRRIntervals?() == true, currentHeartRate?() != nil,
              let currentStream = currentRRStreamID?() else {
            fail("HRV requires fresh beat intervals from your connected heart rate monitor. Check your strap connection and contact, then try again.")
            return
        }
        stopLiveHeartRateUpdates()
        startTime = nowProvider()
        startTicks = ticksProvider()
        streamID = currentStream
        // Identity, not array offsets: the manager's rolling history can be pruned.
        seenIntervals = Set((getRRIntervals?() ?? []).map(\.id))
        currentBPM = currentHeartRate?()
        state = .countingDown
        AppAnalytics.signal(.hrvStart)
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMeasurement() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Timer callbacks only refresh the display; monotonic time defines the window.
    func updateMeasurement() {
        guard state == .countingDown, let startTicks else { return }
        guard currentRRStreamID?() == streamID, supportsRRIntervals?() == true else {
            fail("The sensor connection or contact changed during measurement. Check your strap and measure again.")
            return
        }
        let nowTicks = ticksProvider()
        let deadline = startTicks + measurementDuration
        for interval in getRRIntervals?() ?? [] where !seenIntervals.contains(interval.id) {
            seenIntervals.insert(interval.id)
            if interval.receivedTicks > startTicks && interval.receivedTicks <= deadline {
                intervals.append(interval)
            }
        }
        currentBPM = currentHeartRate?()
        // Keep real receipt times for the accompanying BPM trace.
        if nowTicks <= deadline, nowTicks - (lastSampleTicks ?? startTicks) >= 1 {
            lastSampleTicks = nowTicks
            if let bpm = currentBPM, bpm > 0 {
                heartRateSamples.append(HRVHeartRateSample(timestamp: nowProvider(), bpm: bpm))
                minHeartRate = min(minHeartRate ?? bpm, bpm)
                maxHeartRate = max(maxHeartRate ?? bpm, bpm)
            }
        }
        remainingTime = max(0, deadline - nowTicks)
        if nowTicks >= deadline {
            completeMeasurement()
        } else if nowTicks - (intervals.last?.receivedTicks ?? startTicks) > 5 {
            fail("Beat data stopped during measurement. Check your strap connection and measure again.")
        }
    }

    private func completeMeasurement() {
        guard let startTicks, let startTime else { return }
        if let error = HRVCalculator.qualityError(intervals: intervals, start: startTicks, duration: measurementDuration) {
            fail(error)
            return
        }
        guard let result = HRVCalculator.rmssd(intervals.map(\.value)) else {
            fail("Unable to calculate HRV from this recording. Please measure again.")
            return
        }
        timer?.invalidate()
        timer = nil
        hrvValue = result
        let values = heartRateSamples.map(\.bpm)
        if !values.isEmpty {
            avgHeartRate = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        }
        completedAt = startTime.addingTimeInterval(measurementDuration)
        state = .completed
        playCompletionFeedback()
        startLiveHeartRateUpdates()
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        timer = nil
        hrvValue = nil
        completedAt = nil
        state = .error(message)
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
    
    func startLiveHeartRateUpdates() {
        stopLiveHeartRateUpdates()
        liveHeartRateTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state != .countingDown else { return }
            self.currentBPM = self.currentHeartRate?()
        }
        RunLoop.main.add(liveHeartRateTimer!, forMode: .common)
    }

    func stopLiveHeartRateUpdates() {
        liveHeartRateTimer?.invalidate()
        liveHeartRateTimer = nil
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        state = .idle
        remainingTime = measurementDuration
        intervals.removeAll()
        seenIntervals.removeAll()
        heartRateSamples.removeAll()
        hrvValue = nil
        avgHeartRate = nil
        minHeartRate = nil
        maxHeartRate = nil
        currentBPM = nil
        startTime = nil
        startTicks = nil
        streamID = nil
        completedAt = nil
        lastSampleTicks = nil
    }

    func hrvRecord(recordId: UUID? = nil) -> HRVRecord? {
        guard isCompleted, let startTime, let completedAt, let hrvValue, hrvValue.isFinite else { return nil }
        return HRVRecord(
            id: recordId ?? UUID(), schemaVersion: HRVRecord.schemaVersion,
            startAt: startTime, endAt: completedAt, durationSeconds: measurementDuration,
            hrvValue: hrvValue, avgHr: avgHeartRate, minHr: minHeartRate, maxHr: maxHeartRate,
            hrSamples: heartRateSamples, rrIntervalsMs: intervals.map(\.value),
            source: "phone", appVersion: appVersionString(), createdAt: nowProvider(), updatedAt: nowProvider()
        )
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    deinit {
        timer?.invalidate()
        liveHeartRateTimer?.invalidate()
    }
}
