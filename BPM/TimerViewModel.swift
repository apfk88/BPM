//
//  TimerViewModel.swift
//  BPM
//
//  Created for timer feature
//

import Foundation
import Combine

enum TimerState {
    case idle
    case running
    case paused
    case cooldown
    case cooldownPaused
}

struct SetRecord: Identifiable {
    let id = UUID()
    let setNumber: Int
    let setTime: TimeInterval
    let heartRate: Int?
    let totalTime: TimeInterval
    let isRestSet: Bool
    let isCooldownSet: Bool // True for cooldown sets (C1, C2), false for regular rest sets (2R, 3R, etc.)
    let associatedWorkSetNumber: Int? // For rest sets, the work set number they're associated with (e.g., 2R means rest after set 2)
}

final class TimerViewModel: ObservableObject {
    @Published var state: TimerState = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var currentSetTime: TimeInterval = 0
    @Published var sets: [SetRecord] = []
    @Published var cooldownTime: TimeInterval = 0
    @Published var frozenElapsedTime: TimeInterval = 0 // Total time frozen at cooldown start
    @Published var isTimingRestSet: Bool = false // True when currently timing a rest set
    
    private var startTime: Date?
    private var pauseStartTime: Date?
    private var timer: Timer?
    private var cooldownTimer: Timer?
    private var cooldownStartTime: Date?
    private var cooldownPauseStartTime: Date?
    private var setCounter = 0
    private var restSetCounter = 0
    private var lastSetEndTime: TimeInterval = 0
    private var currentRestAssociatedWorkSetNumber: Int?
    private var restStartTime: Date? // Start time for rest period
    private var cooldownOneMinuteTimer: Timer?
    private var cooldownTwoMinuteTimer: Timer?
    private var heartRateSamples: [HeartRateSample] = [] // Track all heart rate samples during workout
    private var heartRateSampleTimer: Timer? // Timer to sample heart rate periodically
    
    var currentHeartRate: (() -> Int?)?
    
    var avgSetTime: TimeInterval? {
        let workoutSets = sets.filter { !$0.isRestSet && !$0.isCooldownSet }
        guard !workoutSets.isEmpty else { return nil }
        let total = workoutSets.reduce(0) { $0 + $1.setTime }
        return total / Double(workoutSets.count)
    }
    
    var avgRestTime: TimeInterval? {
        // Only include completed rest sets (exclude active rest sets with 0 time)
        let restSets = sets.filter { $0.isRestSet && !$0.isCooldownSet && $0.setTime > 0 }
        guard !restSets.isEmpty else { return nil }
        let total = restSets.reduce(0) { $0 + $1.setTime }
        return total / Double(restSets.count)
    }
    
    var avgHeartRate: Int? {
        // Calculate average from all heart rate samples during the workout (excluding paused time)
        guard !heartRateSamples.isEmpty else { return nil }
        let total = heartRateSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(heartRateSamples.count)).rounded())
    }
    
    var maxHeartRate: Int? {
        // Calculate max from all heart rate samples during the workout
        guard !heartRateSamples.isEmpty else {
            // Fallback to current heart rate if no samples yet
            return currentHeartRate?()
        }
        let maxFromSamples = heartRateSamples.map { $0.value }.max()
        
        // Also consider current heart rate if timer is running
        if state == .running || state == .paused, let currentHR = currentHeartRate?() {
            if let maxFromSamples = maxFromSamples {
                return max(maxFromSamples, currentHR)
            } else {
                return currentHR
            }
        }
        
        return maxFromSamples
    }
    
    var isCompleted: Bool {
        state == .idle && !sets.isEmpty
    }
    
    var isInCooldownMode: Bool {
        state == .cooldown || state == .cooldownPaused
    }
    
    // Get display label for a set (e.g., "1", "2R", "C1", "C2")
    func displayLabel(for set: SetRecord) -> String {
        if set.isCooldownSet {
            return "C\(set.setNumber)"
        } else if set.isRestSet {
            if let workSetNumber = set.associatedWorkSetNumber {
                return "\(workSetNumber)R"
            }
            return "R\(set.setNumber)"
        } else {
            return "\(set.setNumber)"
        }
    }
    
    func isActiveRestSet(_ set: SetRecord) -> Bool {
        guard isTimingRestSet else { return false }
        guard set.isRestSet && !set.isCooldownSet else { return false }
        return set.associatedWorkSetNumber == currentRestAssociatedWorkSetNumber
    }
    
    func displaySetTime(for set: SetRecord) -> TimeInterval {
        if isActiveRestSet(set) {
            return max(0, currentSetTime)
        }
        return set.setTime
    }
    
    func displayTotalTime(for set: SetRecord) -> TimeInterval {
        if isActiveRestSet(set) {
            return elapsedTime
        }
        return set.totalTime
    }
    
    func displayAvgBPM(for set: SetRecord) -> Int? {
        if isActiveRestSet(set) {
            return avgBPMForCurrentSet()
        }
        return avgBPMForSet(set)
    }
    
    func displayMaxBPM(for set: SetRecord) -> Int? {
        if isActiveRestSet(set) {
            return maxBPMForCurrentSet()
        }
        return maxBPMForSet(set)
    }
    
    func displayMinBPM(for set: SetRecord) -> Int? {
        if isActiveRestSet(set) {
            return minBPMForCurrentSet()
        }
        return minBPMForSet(set)
    }
    
    // Calculate average BPM for a specific set based on heart rate samples during that set's time period
    func avgBPMForSet(_ set: SetRecord) -> Int? {
        guard let startTime = startTime else { return nil }
        let setStartTime = startTime.addingTimeInterval(set.totalTime - set.setTime)
        let setEndTime = startTime.addingTimeInterval(set.totalTime)
        
        let samplesInSet = heartRateSamples.filter { sample in
            sample.timestamp >= setStartTime && sample.timestamp <= setEndTime
        }
        
        guard !samplesInSet.isEmpty else { return set.heartRate }
        let total = samplesInSet.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(samplesInSet.count)).rounded())
    }
    
    // Calculate max BPM for a specific set based on heart rate samples during that set's time period
    func maxBPMForSet(_ set: SetRecord) -> Int? {
        guard let startTime = startTime else { return nil }
        let setStartTime = startTime.addingTimeInterval(set.totalTime - set.setTime)
        let setEndTime = startTime.addingTimeInterval(set.totalTime)
        
        let samplesInSet = heartRateSamples.filter { sample in
            sample.timestamp >= setStartTime && sample.timestamp <= setEndTime
        }
        
        guard !samplesInSet.isEmpty else { return set.heartRate }
        return samplesInSet.map { $0.value }.max()
    }
    
    // Calculate average BPM for the current set being timed
    func avgBPMForCurrentSet() -> Int? {
        guard let startTime = startTime else { return nil }
        let currentSetStartTime = startTime.addingTimeInterval(lastSetEndTime)
        let now = Date()
        
        let samplesInCurrentSet = heartRateSamples.filter { sample in
            sample.timestamp >= currentSetStartTime && sample.timestamp <= now
        }
        
        guard !samplesInCurrentSet.isEmpty else { return currentHeartRate?() }
        let total = samplesInCurrentSet.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(samplesInCurrentSet.count)).rounded())
    }
    
    // Calculate max BPM for the current set being timed
    func maxBPMForCurrentSet() -> Int? {
        guard let startTime = startTime else { return nil }
        let currentSetStartTime = startTime.addingTimeInterval(lastSetEndTime)
        let now = Date()
        
        let samplesInCurrentSet = heartRateSamples.filter { sample in
            sample.timestamp >= currentSetStartTime && sample.timestamp <= now
        }
        
        guard !samplesInCurrentSet.isEmpty else { return currentHeartRate?() }
        let maxFromSamples = samplesInCurrentSet.map { $0.value }.max()
        
        // Also consider current heart rate
        if let currentHR = currentHeartRate?() {
            if let maxFromSamples = maxFromSamples {
                return max(maxFromSamples, currentHR)
            } else {
                return currentHR
            }
        }
        
        return maxFromSamples
    }
    
    // Calculate min BPM for a specific set based on heart rate samples during that set's time period
    func minBPMForSet(_ set: SetRecord) -> Int? {
        guard let startTime = startTime else { return nil }
        let setStartTime = startTime.addingTimeInterval(set.totalTime - set.setTime)
        let setEndTime = startTime.addingTimeInterval(set.totalTime)
        
        let samplesInSet = heartRateSamples.filter { sample in
            sample.timestamp >= setStartTime && sample.timestamp <= setEndTime
        }
        
        guard !samplesInSet.isEmpty else { return set.heartRate }
        return samplesInSet.map { $0.value }.min()
    }
    
    // Calculate min BPM for the current set being timed
    func minBPMForCurrentSet() -> Int? {
        guard let startTime = startTime else { return nil }
        let currentSetStartTime = startTime.addingTimeInterval(lastSetEndTime)
        let now = Date()
        
        let samplesInCurrentSet = heartRateSamples.filter { sample in
            sample.timestamp >= currentSetStartTime && sample.timestamp <= now
        }
        
        guard !samplesInCurrentSet.isEmpty else { return currentHeartRate?() }
        let minFromSamples = samplesInCurrentSet.map { $0.value }.min()
        
        // Also consider current heart rate
        if let currentHR = currentHeartRate?() {
            if let minFromSamples = minFromSamples {
                return min(minFromSamples, currentHR)
            } else {
                return currentHR
            }
        }
        
        return minFromSamples
    }
    
    func start() {
        guard state == .idle || state == .paused else { return }
        
        if state == .idle {
            startTime = Date()
            pauseStartTime = nil
            setCounter = 0
            restSetCounter = 0
            lastSetEndTime = 0
            isTimingRestSet = false // Start with work set
            currentRestAssociatedWorkSetNumber = nil
            sets.removeAll()
            heartRateSamples.removeAll()
            startHeartRateSampling()
        } else if state == .paused {
            // Resume from paused state - adjust startTime to account for total elapsed time
            if let pauseStartTime = pauseStartTime {
                // Calculate how long we were paused (this doesn't count toward elapsed time)
                let pauseDuration = Date().timeIntervalSince(pauseStartTime)
                // Adjust startTime backward by the pause duration so elapsed time calculation is correct
                startTime = (startTime ?? Date()).addingTimeInterval(pauseDuration)
                self.pauseStartTime = nil
            }
            startHeartRateSampling()
        }
        
        state = .running
        startTimer()
    }
    
    func stop() {
        guard state == .running else { return }
        state = .paused
        stopTimer()
        pauseStartTime = Date()
        stopHeartRateSampling()
    }
    
    func captureSet() {
        guard (state == .running || state == .paused), let startTime = startTime else { return }
        
        let currentTotalTime = state == .paused ? elapsedTime : Date().timeIntervalSince(startTime)
        let segmentTime = max(0, currentTotalTime - lastSetEndTime)
        let heartRate = currentHeartRate?()
        
        if isTimingRestSet {
            // Update the existing rest set record (it was created with 0 time when Rest Set was pressed)
            if let lastRestSetIndex = sets.lastIndex(where: { $0.isRestSet && !$0.isCooldownSet && $0.setNumber == currentRestAssociatedWorkSetNumber }) {
                let associatedNumber = currentRestAssociatedWorkSetNumber ?? setCounter
                let updatedRestSet = SetRecord(
                    setNumber: associatedNumber,
                    setTime: segmentTime,
                    heartRate: heartRate,
                    totalTime: currentTotalTime,
                    isRestSet: true,
                    isCooldownSet: false,
                    associatedWorkSetNumber: associatedNumber
                )
                sets[lastRestSetIndex] = updatedRestSet
            }
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
        } else {
            setCounter += 1
            let workSetRecord = SetRecord(
                setNumber: setCounter,
                setTime: segmentTime,
                heartRate: heartRate,
                totalTime: currentTotalTime,
                isRestSet: false,
                isCooldownSet: false,
                associatedWorkSetNumber: nil
            )
            
            sets.append(workSetRecord)
            currentRestAssociatedWorkSetNumber = nil
        }
        
        lastSetEndTime = currentTotalTime
        currentSetTime = 0
    }
    
    func captureRestSet() {
        guard (state == .running || state == .paused), !isTimingRestSet, let startTime = startTime else { return }
        
        let currentTotalTime = state == .paused ? elapsedTime : Date().timeIntervalSince(startTime)
        let segmentTime = max(0, currentTotalTime - lastSetEndTime)
        let heartRate = currentHeartRate?()
        let workSets = sets.filter { !$0.isRestSet && !$0.isCooldownSet }
        let tolerance: TimeInterval = 0.01
        
        let workSetNumber: Int
        
        if let lastWorkSet = workSets.last,
           abs(lastWorkSet.totalTime - currentTotalTime) <= tolerance {
            // Work set already captured (e.g., via Work Set button)
            workSetNumber = lastWorkSet.setNumber
        } else {
            // Finalize the current work segment as a new work set
            setCounter += 1
            workSetNumber = setCounter
            
            let workSetRecord = SetRecord(
                setNumber: workSetNumber,
                setTime: segmentTime,
                heartRate: heartRate,
                totalTime: currentTotalTime,
                isRestSet: false,
                isCooldownSet: false,
                associatedWorkSetNumber: nil
            )
            
            sets.append(workSetRecord)
        }
        
        lastSetEndTime = currentTotalTime
        
        // Immediately create the rest set record with 0 time - it will be updated when Work Set is pressed
        let restSetRecord = SetRecord(
            setNumber: workSetNumber,
            setTime: 0,
            heartRate: heartRate,
            totalTime: currentTotalTime,
            isRestSet: true,
            isCooldownSet: false,
            associatedWorkSetNumber: workSetNumber
        )
        
        sets.append(restSetRecord)
        currentSetTime = 0
        
        isTimingRestSet = true
        currentRestAssociatedWorkSetNumber = workSetNumber
    }
    
    func end() {
        guard state == .running || state == .paused else { return }
        
        stopTimer()
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        // Freeze the total elapsed time
        frozenElapsedTime = elapsedTime
        // Start tracking rest time
        restStartTime = Date()
        state = .cooldown
        cooldownStartTime = Date()
        cooldownTime = 0
        cooldownPauseStartTime = nil
        startCooldownTimer()
    }
    
    func toggleCooldown() {
        if state == .cooldown {
            // Pause cooldown
            state = .cooldownPaused
            stopCooldownTimer()
            cooldownPauseStartTime = Date()
            // Pause rest timer
            if let restStartTime = restStartTime {
                let restElapsed = Date().timeIntervalSince(restStartTime)
                currentSetTime = restElapsed
                self.restStartTime = nil
            }
        } else if state == .cooldownPaused {
            // Resume cooldown
            state = .cooldown
            if let cooldownPauseStartTime = cooldownPauseStartTime {
                let pauseDuration = Date().timeIntervalSince(cooldownPauseStartTime)
                // Adjust cooldown start time to account for pause
                cooldownStartTime = (cooldownStartTime ?? Date()).addingTimeInterval(pauseDuration)
                // Adjust rest start time to account for pause
                restStartTime = Date().addingTimeInterval(-currentSetTime)
                self.cooldownPauseStartTime = nil
            }
            startCooldownTimer()
        }
    }
    
    func stopAndComplete() {
        guard state == .running || state == .paused else { return }
        
        stopTimer()
        stopHeartRateSampling()
        frozenElapsedTime = elapsedTime
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        state = .idle
    }
    
    func stopCooldownAndComplete() {
        guard state == .cooldown || state == .cooldownPaused else { return }
        
        let cooldownElapsed = currentSetTime
        if cooldownElapsed > 0 {
            let nextCooldownNumber = restSetCounter + 1
            let totalTime = frozenElapsedTime + cooldownElapsed
            let heartRate = currentHeartRate?()
            
            let cooldownRecord = SetRecord(
                setNumber: nextCooldownNumber,
                setTime: cooldownElapsed,
                heartRate: heartRate,
                totalTime: totalTime,
                isRestSet: true,
                isCooldownSet: true,
                associatedWorkSetNumber: nil
            )
            
            restSetCounter = nextCooldownNumber
            sets.append(cooldownRecord)
        }
        
        stopCooldownTimer()
        stopHeartRateSampling()
        // If we're ending during cooldown, capture the current rest time if needed
        // But don't add it as a set - just end
        restStartTime = nil
        cooldownStartTime = nil
        cooldownPauseStartTime = nil
        currentSetTime = 0
        cooldownTime = 0
        currentRestAssociatedWorkSetNumber = nil
        isTimingRestSet = false
        state = .idle
    }
    
    func reset() {
        stopTimer()
        stopCooldownTimer()
        stopHeartRateSampling()
        state = .idle
        elapsedTime = 0
        currentSetTime = 0
        pauseStartTime = nil
        startTime = nil
        cooldownStartTime = nil
        cooldownPauseStartTime = nil
        restStartTime = nil
        cooldownTime = 0
        setCounter = 0
        restSetCounter = 0
        lastSetEndTime = 0
        frozenElapsedTime = 0
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        sets.removeAll()
        heartRateSamples.removeAll()
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let startTime = self.startTime {
                    self.elapsedTime = Date().timeIntervalSince(startTime)
                    // Calculate current set time
                    self.currentSetTime = self.elapsedTime - self.lastSetEndTime
                }
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func startHeartRateSampling() {
        heartRateSampleTimer?.invalidate()
        // Sample heart rate every second (1 Hz) to match main mode behavior
        heartRateSampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let heartRate = self.currentHeartRate?() {
                    let sample = HeartRateSample(value: heartRate, timestamp: Date())
                    self.heartRateSamples.append(sample)
                }
            }
        }
        RunLoop.current.add(heartRateSampleTimer!, forMode: .common)
    }
    
    private func stopHeartRateSampling() {
        heartRateSampleTimer?.invalidate()
        heartRateSampleTimer = nil
    }
    
    private func startCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownOneMinuteTimer?.invalidate()
        cooldownTwoMinuteTimer?.invalidate()
        
        guard let cooldownStartTime = cooldownStartTime else { return }
        let elapsed = Date().timeIntervalSince(cooldownStartTime)
        
        // Capture heart rate at 1 minute (if not already passed)
        if elapsed < 60.0 {
            let remaining1Min = 60.0 - elapsed
            cooldownOneMinuteTimer = Timer.scheduledTimer(withTimeInterval: remaining1Min, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.state == .cooldown {
                    self.captureCooldownHeartRate(minute: 1)
                }
            }
        }
        
        // Capture heart rate at 2 minutes and stop (if not already passed)
        if elapsed < 120.0 {
            let remaining2Min = 120.0 - elapsed
            cooldownTwoMinuteTimer = Timer.scheduledTimer(withTimeInterval: remaining2Min, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.state == .cooldown {
                    self.captureCooldownHeartRate(minute: 2)
                    self.stopCooldownTimer()
                    DispatchQueue.main.async {
                        self.state = .idle
                    }
                }
            }
        }
        
        // Update cooldown time display and rest time
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let cooldownStartTime = self.cooldownStartTime {
                    self.cooldownTime = Date().timeIntervalSince(cooldownStartTime)
                }
                // Update rest time (currentSetTime) during cooldown
                if let restStartTime = self.restStartTime {
                    self.currentSetTime = Date().timeIntervalSince(restStartTime)
                }
            }
        }
        RunLoop.current.add(cooldownTimer!, forMode: .common)
    }
    
    private func stopCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownOneMinuteTimer?.invalidate()
        cooldownOneMinuteTimer = nil
        cooldownTwoMinuteTimer?.invalidate()
        cooldownTwoMinuteTimer = nil
    }
    
    private func captureCooldownHeartRate(minute: Int) {
        guard cooldownStartTime != nil else { return }
        
        let workoutTime = sets.isEmpty ? 0 : (sets.last?.totalTime ?? 0)
        let cooldownElapsed = TimeInterval(minute * 60)
        let totalTime = workoutTime + cooldownElapsed
        let heartRate = currentHeartRate?()
        
        restSetCounter += 1
        let setRecord = SetRecord(
            setNumber: restSetCounter,
            setTime: cooldownElapsed,
            heartRate: heartRate,
            totalTime: totalTime,
            isRestSet: true,
            isCooldownSet: true,
            associatedWorkSetNumber: nil
        )
        
        DispatchQueue.main.async {
            self.sets.append(setRecord)
        }
    }
    
    deinit {
        timer?.invalidate()
        cooldownTimer?.invalidate()
        cooldownOneMinuteTimer?.invalidate()
        cooldownTwoMinuteTimer?.invalidate()
        heartRateSampleTimer?.invalidate()
    }
}

