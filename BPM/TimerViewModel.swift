//
//  TimerViewModel.swift
//  BPM
//
//  Created for timer feature
//

import Foundation
import Combine
import AudioToolbox
import AVFoundation

enum TimerState {
    case idle
    case running
    case paused
    case cooldown
    case cooldownPaused
}

enum PresetPhase {
    case work
    case rest
    case cooldown
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

    // Preset mode properties
    @Published var activePreset: TimerPreset? = nil
    @Published var presetPhase: PresetPhase = .work
    @Published var presetCurrentSet: Int = 0 // Current set number (1-indexed)
    @Published var presetPhaseTimeRemaining: TimeInterval = 0 // Countdown for current phase

    var isPresetMode: Bool {
        activePreset != nil
    }

    // Returns placeholder rows for preset preview (works during idle and execution)
    var presetPlaceholderSets: [SetRecord] {
        guard let preset = activePreset else { return [] }

        var placeholders: [SetRecord] = []
        var runningTime: TimeInterval = 0

        for setNum in 1...preset.numberOfSets {
            // Work set
            runningTime += preset.workDuration
            placeholders.append(SetRecord(
                setNumber: setNum,
                setTime: preset.workDuration,
                heartRate: nil,
                totalTime: runningTime,
                isRestSet: false,
                isCooldownSet: false,
                associatedWorkSetNumber: nil
            ))

            // Rest set (except after last set)
            if setNum < preset.numberOfSets {
                runningTime += preset.restDuration
                placeholders.append(SetRecord(
                    setNumber: setNum,
                    setTime: preset.restDuration,
                    heartRate: nil,
                    totalTime: runningTime,
                    isRestSet: true,
                    isCooldownSet: false,
                    associatedWorkSetNumber: setNum
                ))
            }
        }

        // Cooldown sets
        if preset.includeCooldown {
            runningTime += 60
            placeholders.append(SetRecord(
                setNumber: 1,
                setTime: 60,
                heartRate: nil,
                totalTime: runningTime,
                isRestSet: true,
                isCooldownSet: true,
                associatedWorkSetNumber: nil
            ))
            runningTime += 60
            placeholders.append(SetRecord(
                setNumber: 2,
                setTime: 60,
                heartRate: nil,
                totalTime: runningTime,
                isRestSet: true,
                isCooldownSet: true,
                associatedWorkSetNumber: nil
            ))
        }

        return placeholders
    }

    // Returns the remaining placeholder sets that haven't been completed yet
    var remainingPresetPlaceholderSets: [SetRecord] {
        guard activePreset != nil else { return [] }

        let allPlaceholders = presetPlaceholderSets
        var skipCount = sets.count

        // If we're currently timing a work or rest set (active row shown separately),
        // we need to skip one more placeholder to avoid doubling up
        if state == .running || state == .paused {
            if !isTimingRestSet {
                // Currently in work phase - skip the current work set placeholder
                skipCount += 1
            }
            // Note: During rest phase, the rest set is already added to sets array,
            // so no extra skip needed
        } else if state == .cooldown || state == .cooldownPaused {
            // During cooldown, active cooldown row is shown separately
            skipCount += 1
        }

        // Return placeholders starting after the completed/active sets
        if skipCount < allPlaceholders.count {
            return Array(allPlaceholders.dropFirst(skipCount))
        }
        return []
    }

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
    private var cooldownStartHeartRate: Int? // Heart rate at start of cooldown
    private var cooldownEndHeartRate: Int? // Heart rate at end of cooldown (2 minutes)
    private var presetPhaseStartTime: Date? // When current preset phase started
    private var presetPhasePausedTime: TimeInterval = 0 // Time paused in current phase
    private var audioPlayer: AVAudioPlayer? // For playing sounds that bypass silent mode

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
        // Calculate average from heart rate samples during the workout only (exclude cooldown samples)
        guard !heartRateSamples.isEmpty, let startTime = startTime else { return nil }
        
        // Filter samples to only include those from the workout period (before cooldown started)
        // If frozenElapsedTime is 0, include all samples (no cooldown yet)
        let workoutSamples: [HeartRateSample]
        if frozenElapsedTime > 0 {
            // Only include samples from before cooldown started
            workoutSamples = heartRateSamples.filter { sample in
                sample.timestamp.timeIntervalSince(startTime) <= frozenElapsedTime
            }
        } else {
            // No cooldown yet, include all samples
            workoutSamples = heartRateSamples
        }
        
        let nonZeroSamples = workoutSamples.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else { return nil }
        let total = nonZeroSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(nonZeroSamples.count)).rounded())
    }
    
    var maxHeartRate: Int? {
        // Calculate max from all heart rate samples during the workout
        guard !heartRateSamples.isEmpty else {
            // Fallback to current heart rate only while actively running
            guard state == .running || state == .paused else { return nil }
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

    var minHeartRate: Int? {
        // Calculate min from all heart rate samples during the workout
        guard !heartRateSamples.isEmpty else {
            // Fallback to current heart rate only while actively running
            guard state == .running || state == .paused else { return nil }
            if let currentHR = currentHeartRate?(), currentHR > 0 {
                return currentHR
            }
            return nil
        }
        let minFromSamples = heartRateSamples.map { $0.value }.filter { $0 > 0 }.min()

        // Also consider current heart rate if timer is running
        if state == .running || state == .paused, let currentHR = currentHeartRate?() {
            guard currentHR > 0 else { return minFromSamples }
            if let minFromSamples = minFromSamples {
                return min(minFromSamples, currentHR)
            } else {
                return currentHR
            }
        }

        return minFromSamples
    }
    
    var heartRateRecovery: Int? {
        // HRR = heart rate at start of cooldown - heart rate at end of cooldown
        guard let startHR = cooldownStartHeartRate, let endHR = cooldownEndHeartRate else {
            return nil
        }
        return startHR - endHR
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
        
        let nonZeroSamples = samplesInSet.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else {
            if let setHeartRate = set.heartRate, setHeartRate > 0 {
                return setHeartRate
            }
            return nil
        }
        let total = nonZeroSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(nonZeroSamples.count)).rounded())
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
        
        let nonZeroSamples = samplesInCurrentSet.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else {
            if let currentHR = currentHeartRate?(), currentHR > 0 {
                return currentHR
            }
            return nil
        }
        let total = nonZeroSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(nonZeroSamples.count)).rounded())
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
        
        let nonZeroSamples = samplesInSet.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else {
            if let setHeartRate = set.heartRate, setHeartRate > 0 {
                return setHeartRate
            }
            return nil
        }
        return nonZeroSamples.map { $0.value }.min()
    }
    
    // Calculate min BPM for the current set being timed
    func minBPMForCurrentSet() -> Int? {
        guard let startTime = startTime else { return nil }
        let currentSetStartTime = startTime.addingTimeInterval(lastSetEndTime)
        let now = Date()
        
        let samplesInCurrentSet = heartRateSamples.filter { sample in
            sample.timestamp >= currentSetStartTime && sample.timestamp <= now
        }
        
        let nonZeroSamples = samplesInCurrentSet.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else {
            if let currentHR = currentHeartRate?(), currentHR > 0 {
                return currentHR
            }
            return nil
        }
        let minFromSamples = nonZeroSamples.map { $0.value }.min()
        
        // Also consider current heart rate
        if let currentHR = currentHeartRate?() {
            guard currentHR > 0 else { return minFromSamples }
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
        // Capture heart rate at start of cooldown
        cooldownStartHeartRate = currentHeartRate?()
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
        
        // Capture heart rate at end of cooldown if not already captured
        if cooldownEndHeartRate == nil {
            cooldownEndHeartRate = currentHeartRate?()
        }
        
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
        cooldownStartHeartRate = nil
        cooldownEndHeartRate = nil
        sets.removeAll()
        heartRateSamples.removeAll()
        // Reset preset state
        activePreset = nil
        presetPhase = .work
        presetCurrentSet = 0
        presetPhaseTimeRemaining = 0
        presetPhaseStartTime = nil
        presetPhasePausedTime = 0
    }

    // MARK: - Preset Mode

    func loadPreset(_ preset: TimerPreset) {
        reset()
        activePreset = preset
        presetPhase = .work
        presetCurrentSet = 1
        presetPhaseTimeRemaining = preset.workDuration
    }

    func clearPreset() {
        activePreset = nil
        presetPhase = .work
        presetCurrentSet = 0
        presetPhaseTimeRemaining = 0
        presetPhaseStartTime = nil
        presetPhasePausedTime = 0
    }

    func startPreset() {
        guard let preset = activePreset, state == .idle || state == .paused else { return }

        if state == .idle {
            startTime = Date()
            pauseStartTime = nil
            setCounter = 0
            restSetCounter = 0
            lastSetEndTime = 0
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
            sets.removeAll()
            heartRateSamples.removeAll()
            presetPhase = .work
            presetCurrentSet = 1
            presetPhaseTimeRemaining = preset.workDuration
            presetPhaseStartTime = Date()
            presetPhasePausedTime = 0
            startHeartRateSampling()
        } else if state == .paused {
            // Resume from paused state
            if let pauseStartTime = pauseStartTime {
                let pauseDuration = Date().timeIntervalSince(pauseStartTime)
                startTime = (startTime ?? Date()).addingTimeInterval(pauseDuration)
                presetPhaseStartTime = (presetPhaseStartTime ?? Date()).addingTimeInterval(pauseDuration)
                self.pauseStartTime = nil
            }
            startHeartRateSampling()
        }

        state = .running
        startPresetTimer()
    }

    func pausePreset() {
        guard state == .running, isPresetMode else { return }
        state = .paused
        stopTimer()
        pauseStartTime = Date()
        // Save how much time has elapsed in current phase
        if let phaseStart = presetPhaseStartTime {
            presetPhasePausedTime = Date().timeIntervalSince(phaseStart)
        }
        stopHeartRateSampling()
    }

    func endPreset() {
        guard isPresetMode, let preset = activePreset else { return }

        // Capture current set if running
        if state == .running || state == .paused {
            if presetPhase == .work {
                capturePresetSet()
            } else if presetPhase == .rest {
                capturePresetRestSet()
            }
        }

        if preset.includeCooldown {
            // Start automatic 2-minute cooldown
            stopTimer()
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
            frozenElapsedTime = elapsedTime
            cooldownStartHeartRate = currentHeartRate?()
            restStartTime = Date()
            state = .cooldown
            cooldownStartTime = Date()
            cooldownTime = 0
            cooldownPauseStartTime = nil
            presetPhase = .cooldown
            presetPhaseTimeRemaining = 120 // 2 minute cooldown
            presetPhaseStartTime = Date()
            presetPhasePausedTime = 0
            startPresetCooldownTimer()
        } else {
            // No cooldown, just complete immediately
            stopTimer()
            stopHeartRateSampling()
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
            frozenElapsedTime = elapsedTime
            state = .idle
            activePreset = nil
        }
    }

    func skipToCooldown() {
        guard isPresetMode, let preset = activePreset, state == .running || state == .paused else { return }
        if preset.includeCooldown {
            endPreset()
        } else {
            // No cooldown option, just complete
            stopPresetAndComplete()
        }
    }

    func stopPresetAndComplete() {
        guard isPresetMode else { return }

        // Capture current set if running
        if state == .running || state == .paused {
            if presetPhase == .work {
                capturePresetSet()
            } else if presetPhase == .rest {
                capturePresetRestSet()
            }
        }

        // Stop immediately without cooldown
        stopTimer()
        stopCooldownTimer()
        stopHeartRateSampling()
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        frozenElapsedTime = elapsedTime
        state = .idle
        activePreset = nil
    }

    private func startPresetTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let preset = self.activePreset else { return }
            DispatchQueue.main.async {
                guard let startTime = self.startTime else { return }

                self.elapsedTime = Date().timeIntervalSince(startTime)
                self.currentSetTime = self.elapsedTime - self.lastSetEndTime

                // Update phase countdown
                if let phaseStart = self.presetPhaseStartTime {
                    let phaseElapsed = Date().timeIntervalSince(phaseStart)
                    let phaseDuration = self.presetPhase == .work ? preset.workDuration : preset.restDuration
                    self.presetPhaseTimeRemaining = max(0, phaseDuration - phaseElapsed)

                    // Check if phase is complete - use >= for precise timing
                    if phaseElapsed >= phaseDuration {
                        self.advancePresetPhase()
                    }
                }
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func playPhaseEndSound() {
        guard let preset = activePreset, preset.playSound else { return }

        // Configure audio session to play sound even when device is silenced
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Fall back to system sound if audio session fails
            AudioServicesPlaySystemSound(1013) // bell
            return
        }

        // Single bell at each phase transition
        let bellCount = Self.bellCount(for: presetPhase)
        playBells(count: bellCount)
    }

    static func bellCount(for phase: PresetPhase) -> Int {
        switch phase {
        case .work, .rest, .cooldown:
            return 1
        }
    }

    private func playBells(count: Int, current: Int = 0) {
        guard current < count else { return }

        let soundURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/sms-received1.caf")
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            if current + 1 < count {
                // Schedule next bell after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.playBells(count: count, current: current + 1)
                }
            }
        } catch {
            AudioServicesPlaySystemSound(1013)
        }
    }

    private func advancePresetPhase() {
        guard let preset = activePreset, let phaseStart = presetPhaseStartTime else { return }

        // Calculate exact end time of previous phase to avoid drift
        let previousPhaseDuration = presetPhase == .work ? preset.workDuration : preset.restDuration
        let exactPhaseEndTime = phaseStart.addingTimeInterval(previousPhaseDuration)

        // Play sound at end of phase
        playPhaseEndSound()

        if presetPhase == .work {
            // Capture the work set
            capturePresetSet()

            if presetCurrentSet >= preset.numberOfSets {
                // All sets complete, start cooldown
                endPreset()
            } else {
                // Move to rest phase
                presetPhase = .rest
                presetPhaseTimeRemaining = preset.restDuration
                presetPhaseStartTime = exactPhaseEndTime // Use exact time, not Date()
                presetPausedTime = 0
                isTimingRestSet = true

                // Create rest set record - use lastSetEndTime which is set to exact duration
                let heartRate = currentHeartRate?()
                let restSetRecord = SetRecord(
                    setNumber: presetCurrentSet,
                    setTime: 0,
                    heartRate: heartRate,
                    totalTime: lastSetEndTime,
                    isRestSet: true,
                    isCooldownSet: false,
                    associatedWorkSetNumber: presetCurrentSet
                )
                sets.append(restSetRecord)
                currentRestAssociatedWorkSetNumber = presetCurrentSet
            }
        } else if presetPhase == .rest {
            // Capture the rest set
            capturePresetRestSet()

            // Move to next work phase
            presetCurrentSet += 1
            presetPhase = .work
            presetPhaseTimeRemaining = preset.workDuration
            presetPhaseStartTime = exactPhaseEndTime // Use exact time, not Date()
            presetPausedTime = 0
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
        }
    }

    private var presetPausedTime: TimeInterval = 0

    private func capturePresetSet() {
        guard let preset = activePreset else { return }

        // Use exact preset duration instead of actual elapsed time to avoid drift
        let segmentTime = preset.workDuration
        let heartRate = currentHeartRate?()

        setCounter += 1

        // Calculate total time based on completed sets
        let previousTotalTime = sets.last?.totalTime ?? 0
        let currentTotalTime = previousTotalTime + segmentTime

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
        lastSetEndTime = currentTotalTime
        currentSetTime = 0
    }

    private func capturePresetRestSet() {
        guard let preset = activePreset else { return }

        // Use exact preset duration instead of actual elapsed time to avoid drift
        let segmentTime = preset.restDuration
        let heartRate = currentHeartRate?()

        // Calculate total time based on last set
        let previousTotalTime = sets.last?.totalTime ?? 0
        let currentTotalTime = previousTotalTime + segmentTime

        // Update the existing rest set record
        if let lastRestSetIndex = sets.lastIndex(where: { $0.isRestSet && !$0.isCooldownSet && $0.associatedWorkSetNumber == currentRestAssociatedWorkSetNumber }) {
            let updatedRestSet = SetRecord(
                setNumber: currentRestAssociatedWorkSetNumber ?? setCounter,
                setTime: segmentTime,
                heartRate: heartRate,
                totalTime: currentTotalTime,
                isRestSet: true,
                isCooldownSet: false,
                associatedWorkSetNumber: currentRestAssociatedWorkSetNumber
            )
            sets[lastRestSetIndex] = updatedRestSet
        }

        lastSetEndTime = currentTotalTime
        currentSetTime = 0
    }

    private func startPresetCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownOneMinuteTimer?.invalidate()
        cooldownTwoMinuteTimer?.invalidate()

        guard cooldownStartTime != nil else { return }

        // Capture heart rate at 1 minute
        cooldownOneMinuteTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .cooldown {
                self.captureCooldownHeartRate(minute: 1)
            }
        }

        // Capture heart rate at 2 minutes and complete
        cooldownTwoMinuteTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .cooldown {
                self.cooldownEndHeartRate = self.currentHeartRate?()
                self.captureCooldownHeartRate(minute: 2)
                self.playPhaseEndSound() // Sound at end of cooldown
                self.stopHeartRateSampling()
                self.stopCooldownTimer()
                DispatchQueue.main.async {
                    self.state = .idle
                    self.activePreset = nil
                }
            }
        }

        // Update cooldown time display
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let cooldownStartTime = self.cooldownStartTime {
                    self.cooldownTime = Date().timeIntervalSince(cooldownStartTime)
                    self.presetPhaseTimeRemaining = max(0, 120 - self.cooldownTime)
                }
                if let restStartTime = self.restStartTime {
                    self.currentSetTime = Date().timeIntervalSince(restStartTime)
                }
            }
        }
        RunLoop.current.add(cooldownTimer!, forMode: .common)
        startHeartRateSampling()
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
                    // Calculate workout time for chart display
                    let workoutTime: TimeInterval
                    if self.frozenElapsedTime > 0 {
                        // During cooldown: workout time = frozen workout time + cooldown time
                        workoutTime = self.frozenElapsedTime + self.cooldownTime
                    } else {
                        // During workout: use elapsedTime (excludes pauses)
                        workoutTime = self.elapsedTime
                    }
                    let sample = HeartRateSample(value: heartRate, timestamp: Date(), workoutTime: workoutTime)
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
                    // Capture heart rate at end of cooldown
                    self.cooldownEndHeartRate = self.currentHeartRate?()
                    self.captureCooldownHeartRate(minute: 2)
                    // Stop heart rate sampling and end workout
                    self.stopHeartRateSampling()
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
    
    // MARK: - Chart Data
    
    struct ChartDataPoint: Identifiable {
        let id = UUID()
        let time: TimeInterval // Time since workout start
        let bpm: Int
    }
    
    struct ChartSegment: Identifiable {
        let id = UUID()
        let startTime: TimeInterval
        let endTime: TimeInterval
        let type: SegmentType
        
        enum SegmentType {
            case work
            case rest
            case cooldown
        }
    }
    
    /// Returns chart data points with time since start and BPM values
    func chartDataPoints() -> [ChartDataPoint] {
        guard startTime != nil else { return [] }
        
        // Include all samples up to current max time (includes cooldown if active)
        let maxTime = chartMaxTime()
        
        return heartRateSamples.compactMap { sample in
            // Use workoutTime if available (excludes pauses), otherwise fall back to timestamp calculation
            let workoutTime: TimeInterval
            if let sampleWorkoutTime = sample.workoutTime {
                workoutTime = sampleWorkoutTime
            } else {
                // Fallback for old samples without workoutTime
                guard let startTime = startTime else { return nil }
                workoutTime = sample.timestamp.timeIntervalSince(startTime)
            }
            
            // Only include samples up to maxTime
            guard workoutTime <= maxTime else { return nil }
            return ChartDataPoint(time: workoutTime, bpm: sample.value)
        }
    }
    
    /// Returns segments for chart shading (work, rest, cooldown)
    func chartSegments() -> [ChartSegment] {
        var segments: [ChartSegment] = []
        
        // Process sets to create segments
        for set in sets {
            let startTime = set.totalTime - set.setTime
            let endTime = set.totalTime
            
            let segmentType: ChartSegment.SegmentType
            if set.isCooldownSet {
                segmentType = .cooldown
            } else if set.isRestSet {
                segmentType = .rest
            } else {
                segmentType = .work
            }
            
            segments.append(ChartSegment(
                startTime: startTime,
                endTime: endTime,
                type: segmentType
            ))
        }
        
        // Add active segment if timer is running or paused
        if state == .running || state == .paused {
            let currentTotalTime = frozenElapsedTime > 0 ? frozenElapsedTime : elapsedTime
            let activeStartTime = lastSetEndTime
            
            if isTimingRestSet {
                // Active rest set
                segments.append(ChartSegment(
                    startTime: activeStartTime,
                    endTime: currentTotalTime,
                    type: .rest
                ))
            } else {
                // Active work set
                segments.append(ChartSegment(
                    startTime: activeStartTime,
                    endTime: currentTotalTime,
                    type: .work
                ))
            }
        }
        
        // Add active cooldown segment if in cooldown
        if state == .cooldown || state == .cooldownPaused {
            let cooldownStartTime = frozenElapsedTime
            let cooldownEndTime = frozenElapsedTime + cooldownTime
            segments.append(ChartSegment(
                startTime: cooldownStartTime,
                endTime: cooldownEndTime,
                type: .cooldown
            ))
        }
        
        return segments
    }
    
    /// Returns the current max time for the chart (for x-axis scaling)
    func chartMaxTime() -> TimeInterval {
        if frozenElapsedTime > 0 {
            return frozenElapsedTime + cooldownTime
        }
        return elapsedTime
    }
    
    // MARK: - Time in Zone Tracking

    /// Returns time spent in each heart rate zone based on heart rate samples
    func timeInZones(config: HeartRateZoneConfig) -> [ZoneTimeData] {
        var zoneDurations: [HeartRateZone: TimeInterval] = [:]

        // Initialize all zones to 0
        for zone in HeartRateZone.allCases {
            zoneDurations[zone] = 0
        }

        // Each sample represents approximately 1 second of time
        // (since we sample at 1 Hz in startHeartRateSampling)
        let sampleInterval: TimeInterval = 1.0

        for sample in heartRateSamples {
            if let zone = HeartRateZone.zone(for: sample.value, config: config) {
                zoneDurations[zone, default: 0] += sampleInterval
            }
        }

        return HeartRateZone.allCases.map { zone in
            ZoneTimeData(zone: zone, duration: zoneDurations[zone] ?? 0)
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
