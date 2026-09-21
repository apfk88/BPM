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
import UIKit

enum TimerState: String, Codable {
    case idle
    case running
    case paused
    case cooldown
    case cooldownPaused
}

enum PresetPhase: String, Codable {
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
    @Published var state: TimerState = .idle {
        didSet {
            updateLiveActivityElapsed(force: true)
        }
    }
    @Published var elapsedTime: TimeInterval = 0
    @Published var currentSetTime: TimeInterval = 0
    @Published var sets: [SetRecord] = []
    @Published var cooldownTime: TimeInterval = 0
    @Published var frozenElapsedTime: TimeInterval = 0 // Total time frozen at cooldown start
    @Published var isTimingRestSet: Bool = false // True when currently timing a rest set
    @Published private(set) var caloriesStatus: CaloriesEstimateStatus = .disabled(missingFields: [])

    // Preset mode properties
    @Published var activePreset: TimerPreset? = nil
    @Published var presetPhase: PresetPhase = .work
    @Published var presetCurrentSet: Int = 0 // Current set number (1-indexed)
    @Published var presetPhaseTimeRemaining: TimeInterval = 0 // Countdown for current phase
    @Published private(set) var isPresetPrestartCountdownActive = false
    @Published private(set) var defaultWorkoutTitle: String?

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

    private let caloriesQueue = DispatchQueue(label: "bpm.calories-estimate", qos: .utility)
    private let presetStartCountdownDuration: TimeInterval
    private let sessionStore: ActiveWorkoutSessionStore
    private let nowProvider: () -> Date
    private var userDefaultsObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?

    init(
        presetStartCountdownDuration: TimeInterval = 5.0,
        sessionStore: ActiveWorkoutSessionStore = .shared,
        nowProvider: (() -> Date)? = nil
    ) {
        self.presetStartCountdownDuration = max(0, presetStartCountdownDuration)
        self.sessionStore = sessionStore
        let saved = sessionStore.load()
        let clock: MeasurementClock
        if let saved, let anchor = saved.clockDate, let ticks = saved.clockTicks,
           let boot = saved.clockBootSessionID, boot == MeasurementClock.bootSessionID,
           MeasurementClock.ticks >= ticks {
            clock = MeasurementClock(anchorDate: anchor, anchorTicks: ticks)
        } else {
            clock = MeasurementClock()
        }
        self.nowProvider = nowProvider ?? clock.now
        caloriesStatus = CaloriesEstimator.estimate(samples: [], profile: UserEnergyProfileStore.currentProfile())
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCaloriesEstimate()
        }
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidEnterBackground()
        }
        willEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillEnterForeground()
        }
        restorePersistedSessionIfAvailable()
    }

    private var pauses: [WorkoutPause] = []
    private var workoutStartedAt: Date?
    private var workoutEndedAt: Date?
    private var heartRateCancellable: AnyCancellable?
    private var isRefreshingTiming = false
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
    private var heartRateSamples: [HeartRateSample] = [] // Track all heart rate samples during workout
    private var cooldownStartHeartRate: Int? // Heart rate at start of cooldown
    private var cooldownEndHeartRate: Int? // Heart rate at end of cooldown (2 minutes)
    private var presetPhaseStartTime: Date? // When current preset phase started
    private var presetPhasePausedTime: TimeInterval = 0 // Time paused in current phase
    private var audioPlayer: AVAudioPlayer? // For playing sounds that bypass silent mode
    private var audioSessionDeactivationToken = UUID()
    private var lastLiveActivityElapsedSeconds: Int?
    private var presetStartCountdownTimer: Timer?
    private var presetStartCountdownEndTime: Date?
    private var presetStartCountdownRemainingOnPause: TimeInterval = 0

    var currentHeartRate: (() -> Int?)?

    var hasRestorableSession: Bool {
        startTime != nil || !sets.isEmpty || activePreset != nil || isPresetPrestartCountdownActive
    }

    private func handleAppDidEnterBackground() {
        persistCurrentSession(referenceDate: nowProvider())
    }

    private func handleAppWillEnterForeground() {
        refreshTiming()
        resumeRuntimeStateIfNeeded()
        persistCurrentSession(referenceDate: nowProvider())
    }

    private func restorePersistedSessionIfAvailable() {
        guard let snapshot = sessionStore.load(), snapshot.hasSession else { return }

        stopTimer()
        stopCooldownTimer()
        stopPresetStartCountdownTimer()

        state = snapshot.state
        elapsedTime = snapshot.elapsedTime
        currentSetTime = snapshot.currentSetTime
        sets = snapshot.sets.map {
            SetRecord(
                setNumber: $0.setNumber,
                setTime: $0.setTime,
                heartRate: $0.heartRate,
                totalTime: $0.totalTime,
                isRestSet: $0.isRestSet,
                isCooldownSet: $0.isCooldownSet,
                associatedWorkSetNumber: $0.associatedWorkSetNumber
            )
        }
        cooldownTime = snapshot.cooldownTime
        frozenElapsedTime = snapshot.frozenElapsedTime
        isTimingRestSet = snapshot.isTimingRestSet
        activePreset = snapshot.activePreset
        presetPhase = snapshot.presetPhase
        presetCurrentSet = snapshot.presetCurrentSet
        presetPhaseTimeRemaining = snapshot.presetPhaseTimeRemaining
        isPresetPrestartCountdownActive = snapshot.isPresetPrestartCountdownActive
        defaultWorkoutTitle = snapshot.defaultWorkoutTitle
        startTime = snapshot.startTime
        workoutStartedAt = snapshot.workoutStartedAt ?? snapshot.startTime
        workoutEndedAt = snapshot.workoutEndedAt
        pauses = snapshot.pauses ?? []
        pauseStartTime = snapshot.pauseStartTime
        cooldownStartTime = snapshot.cooldownStartTime
        cooldownPauseStartTime = snapshot.cooldownPauseStartTime
        setCounter = snapshot.setCounter
        restSetCounter = snapshot.restSetCounter
        lastSetEndTime = snapshot.lastSetEndTime
        currentRestAssociatedWorkSetNumber = snapshot.currentRestAssociatedWorkSetNumber
        restStartTime = snapshot.restStartTime
        heartRateSamples = snapshot.heartRateSamples.map {
            HeartRateSample(value: $0.value, timestamp: $0.timestamp, workoutTime: $0.workoutTime)
        }
        cooldownStartHeartRate = snapshot.cooldownStartHeartRate
        cooldownEndHeartRate = snapshot.cooldownEndHeartRate
        presetPhaseStartTime = snapshot.presetPhaseStartTime
        presetStartCountdownRemainingOnPause = snapshot.presetStartCountdownRemainingOnPause
        presetStartCountdownEndTime = snapshot.presetStartCountdownEndTime

        updateCaloriesEstimate()
        refreshTiming()
        resumeRuntimeStateIfNeeded()
        updateLiveActivityElapsed(force: true)
        persistCurrentSession(referenceDate: nowProvider())
    }

    private func syncDerivedState(referenceDate: Date, allowPresetCountdownCompletion: Bool) {
        if isPresetPrestartCountdownActive {
            let remaining = resolvedPresetCountdownRemaining(at: referenceDate)
            presetPhaseTimeRemaining = remaining
            presetStartCountdownRemainingOnPause = remaining
            elapsedTime = 0
            currentSetTime = 0

            if remaining <= 0, allowPresetCountdownCompletion {
                completePersistedPresetCountdown(at: referenceDate)
            }
            return
        }

        switch state {
        case .running:
            if let startTime {
                elapsedTime = max(0, referenceDate.timeIntervalSince(startTime))
                currentSetTime = max(0, elapsedTime - lastSetEndTime)
            }
        case .paused:
            if let startTime, let pauseStartTime {
                elapsedTime = max(0, pauseStartTime.timeIntervalSince(startTime))
                currentSetTime = max(0, elapsedTime - lastSetEndTime)
            }
        case .cooldown:
            if let cooldownStartTime {
                cooldownTime = max(0, referenceDate.timeIntervalSince(cooldownStartTime))
            }
            if let restStartTime {
                currentSetTime = max(0, referenceDate.timeIntervalSince(restStartTime))
            }
        case .cooldownPaused:
            if let cooldownStartTime, let cooldownPauseStartTime {
                cooldownTime = max(0, cooldownPauseStartTime.timeIntervalSince(cooldownStartTime))
            }
        case .idle:
            break
        }

        guard let preset = activePreset else { return }

        switch state {
        case .running:
            if let presetPhaseStartTime {
                let phaseDuration = presetPhase == .work ? preset.workDuration : preset.restDuration
                let phaseElapsed = max(0, referenceDate.timeIntervalSince(presetPhaseStartTime))
                presetPhaseTimeRemaining = max(0, phaseDuration - phaseElapsed)
            }
        case .cooldown:
            presetPhaseTimeRemaining = max(0, 120 - cooldownTime)
        default:
            break
        }
    }

    private func resumeRuntimeStateIfNeeded() {
        switch state {
        case .running:
            stopCooldownTimer()

            if isPresetMode {
                if isPresetPrestartCountdownActive {
                    let remaining = resolvedPresetCountdownRemaining(at: nowProvider())
                    if remaining > 0 {
                        startPresetStartCountdownTimer(remaining: remaining)
                    } else {
                        completePersistedPresetCountdown(at: nowProvider())
                        startPresetTimer()
                    }
                } else {
                    startPresetTimer()
                }
            } else {
                startTimer()
            }
        case .paused:
            stopTimer()
            stopCooldownTimer()
            stopPresetStartCountdownTimer()
        case .cooldown:
            stopTimer()
            stopPresetStartCountdownTimer()
            if isPresetMode {
                startPresetCooldownTimer()
            } else {
                startCooldownTimer()
            }
        case .cooldownPaused:
            stopTimer()
            stopCooldownTimer()
            stopPresetStartCountdownTimer()
        case .idle:
            stopTimer()
            stopCooldownTimer()
            stopPresetStartCountdownTimer()
        }
    }

    private func resolvedPresetCountdownRemaining(at referenceDate: Date) -> TimeInterval {
        if let presetStartCountdownEndTime {
            return max(0, presetStartCountdownEndTime.timeIntervalSince(referenceDate))
        }
        return max(0, presetStartCountdownRemainingOnPause)
    }

    private func completePersistedPresetCountdown(at referenceDate: Date) {
        guard let preset = activePreset else { return }
        let deadline = presetStartCountdownEndTime ?? referenceDate
        stopPresetStartCountdownTimer()
        isPresetPrestartCountdownActive = false
        presetStartCountdownRemainingOnPause = 0
        startTime = deadline
        workoutStartedAt = deadline
        workoutEndedAt = nil
        elapsedTime = max(0, referenceDate.timeIntervalSince(deadline))
        currentSetTime = elapsedTime
        pauseStartTime = nil
        presetPhase = .work
        presetCurrentSet = 1
        presetPhaseTimeRemaining = preset.workDuration
        presetPhaseStartTime = deadline
        presetPhasePausedTime = 0
        state = .running
    }

    private func persistCurrentSession(referenceDate: Date? = nil) {
        let referenceDate = referenceDate ?? nowProvider()
        syncDerivedState(referenceDate: referenceDate, allowPresetCountdownCompletion: false)

        guard hasRestorableSession else {
            sessionStore.clear()
            return
        }

        let snapshot = ActiveWorkoutSessionSnapshot(
            schemaVersion: ActiveWorkoutSessionSnapshot.currentSchemaVersion,
            state: state,
            elapsedTime: elapsedTime,
            currentSetTime: currentSetTime,
            sets: sets.map {
                PersistedSetRecord(
                    setNumber: $0.setNumber,
                    setTime: $0.setTime,
                    heartRate: $0.heartRate,
                    totalTime: $0.totalTime,
                    isRestSet: $0.isRestSet,
                    isCooldownSet: $0.isCooldownSet,
                    associatedWorkSetNumber: $0.associatedWorkSetNumber
                )
            },
            cooldownTime: cooldownTime,
            frozenElapsedTime: frozenElapsedTime,
            isTimingRestSet: isTimingRestSet,
            activePreset: activePreset,
            presetPhase: presetPhase,
            presetCurrentSet: presetCurrentSet,
            presetPhaseTimeRemaining: presetPhaseTimeRemaining,
            isPresetPrestartCountdownActive: isPresetPrestartCountdownActive,
            defaultWorkoutTitle: defaultWorkoutTitle,
            startTime: startTime,
            pauseStartTime: pauseStartTime,
            cooldownStartTime: cooldownStartTime,
            cooldownPauseStartTime: cooldownPauseStartTime,
            setCounter: setCounter,
            restSetCounter: restSetCounter,
            lastSetEndTime: lastSetEndTime,
            currentRestAssociatedWorkSetNumber: currentRestAssociatedWorkSetNumber,
            restStartTime: restStartTime,
            heartRateSamples: heartRateSamples.map {
                PersistedHeartRateSample(value: $0.value, timestamp: $0.timestamp, workoutTime: $0.workoutTime)
            },
            cooldownStartHeartRate: cooldownStartHeartRate,
            cooldownEndHeartRate: cooldownEndHeartRate,
            presetPhaseStartTime: presetPhaseStartTime,
            presetStartCountdownRemainingOnPause: presetStartCountdownRemainingOnPause,
            presetStartCountdownEndTime: presetStartCountdownEndTime,
            clockDate: referenceDate,
            clockTicks: MeasurementClock.ticks,
            clockBootSessionID: MeasurementClock.bootSessionID,
            pauses: pauses,
            workoutStartedAt: workoutStartedAt,
            workoutEndedAt: workoutEndedAt
        )

        sessionStore.save(snapshot)
    }
    
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
    
    private var workoutMeasurementEnd: TimeInterval {
        frozenElapsedTime > 0 ? frozenElapsedTime : elapsedTime
    }

    var avgHeartRate: Int? { averageBPM(from: 0, through: workoutMeasurementEnd) }
    var maxHeartRate: Int? { samples(from: -1, through: workoutMeasurementEnd).map(\.value).max() }
    var minHeartRate: Int? { samples(from: -1, through: workoutMeasurementEnd).map(\.value).min() }

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
        averageBPM(from: set.totalTime - set.setTime, through: set.totalTime) ?? set.heartRate
    }

    // Calculate max BPM for a specific set based on heart rate samples during that set's time period
    func maxBPMForSet(_ set: SetRecord) -> Int? {
        let samplesInSet = samples(from: set.totalTime - set.setTime, through: set.totalTime)
        guard !samplesInSet.isEmpty else { return set.heartRate }
        return samplesInSet.map { $0.value }.max()
    }
    
    // Calculate average BPM for the current set being timed
    func avgBPMForCurrentSet() -> Int? {
        averageBPM(from: lastSetEndTime, through: elapsedTime)
    }

    // Calculate max BPM for the current set being timed
    func maxBPMForCurrentSet() -> Int? {
        samples(from: lastSetEndTime, through: elapsedTime).map(\.value).max()
    }
    
    // Calculate min BPM for a specific set based on heart rate samples during that set's time period
    func minBPMForSet(_ set: SetRecord) -> Int? {
        let samplesInSet = samples(from: set.totalTime - set.setTime, through: set.totalTime)
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
        samples(from: lastSetEndTime, through: elapsedTime).map(\.value).min()
    }
    
    func start() {
        guard state == .idle || state == .paused else { return }
        
        if state == .idle {
            reset()
            AppAnalytics.signal(.workoutStart)
            defaultWorkoutTitle = nil
            startTime = nowProvider()
            workoutStartedAt = startTime
            workoutEndedAt = nil
            pauseStartTime = nil
            setCounter = 0
            restSetCounter = 0
            lastSetEndTime = 0
            isTimingRestSet = false // Start with work set
            currentRestAssociatedWorkSetNumber = nil
            sets.removeAll()
            heartRateSamples.removeAll()
            updateCaloriesEstimate()
        } else if state == .paused {
            // Resume from paused state - adjust startTime to account for total elapsed time
            if let pauseStartTime = pauseStartTime {
                // Calculate how long we were paused (this doesn't count toward elapsed time)
                let resumedAt = nowProvider()
                pauses.append(WorkoutPause(start: pauseStartTime, end: resumedAt))
                let pauseDuration = resumedAt.timeIntervalSince(pauseStartTime)
                // Adjust startTime backward by the pause duration so elapsed time calculation is correct
                startTime = (startTime ?? nowProvider()).addingTimeInterval(pauseDuration)
                self.pauseStartTime = nil
            }
        }
        
        state = .running
        startTimer()
        persistCurrentSession()
    }
    
    func stop() {
        refreshTiming()
        guard state == .running else { return }
        state = .paused
        stopTimer()
        pauseStartTime = nowProvider()
        persistCurrentSession()
    }
    
    func captureSet() {
        guard (state == .running || state == .paused), let startTime = startTime else { return }
        
        let currentTotalTime = state == .paused ? elapsedTime : nowProvider().timeIntervalSince(startTime)
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
        persistCurrentSession()
    }
    
    func captureRestSet() {
        guard (state == .running || state == .paused), !isTimingRestSet, let startTime = startTime else { return }
        
        let currentTotalTime = state == .paused ? elapsedTime : nowProvider().timeIntervalSince(startTime)
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
        persistCurrentSession()
    }
    
    func end() {
        refreshTiming()
        guard state == .running || state == .paused else { return }
        frozenElapsedTime = elapsedTime
        stopTimer()
        beginCooldown(at: nowProvider(), heartRate: currentHeartRate?())
        persistCurrentSession()
    }
    
    func toggleCooldown() {
        refreshTiming()
        if state == .cooldown {
            // Pausing changes the real recovery interval, so a two-minute HRR
            // must not be reported for this cooldown.
            cooldownStartHeartRate = nil
            // Pause cooldown
            state = .cooldownPaused
            stopCooldownTimer()
            cooldownPauseStartTime = nowProvider()
            // Pause rest timer
            if let restStartTime = restStartTime {
                let restElapsed = nowProvider().timeIntervalSince(restStartTime)
                currentSetTime = restElapsed
                self.restStartTime = nil
            }
        } else if state == .cooldownPaused {
            // Resume cooldown
            state = .cooldown
            if let cooldownPauseStartTime = cooldownPauseStartTime {
                let resumedAt = nowProvider()
                pauses.append(WorkoutPause(start: cooldownPauseStartTime, end: resumedAt))
                let pauseDuration = resumedAt.timeIntervalSince(cooldownPauseStartTime)
                // Adjust cooldown start time to account for pause
                cooldownStartTime = (cooldownStartTime ?? nowProvider()).addingTimeInterval(pauseDuration)
                // Adjust rest start time to account for pause
                restStartTime = nowProvider().addingTimeInterval(-currentSetTime)
                self.cooldownPauseStartTime = nil
            }
            startCooldownTimer()
        }
        persistCurrentSession()
    }
    
    func stopAndComplete() {
        refreshTiming()
        guard state == .running || state == .paused else { return }
        frozenElapsedTime = elapsedTime
        finishWorkout(at: pauseStartTime ?? nowProvider())
        persistCurrentSession()
    }
    
    func stopCooldownAndComplete() {
        refreshTiming()
        guard state == .cooldown || state == .cooldownPaused else { return }
        let completedCooldown = Double(sets.filter(\.isCooldownSet).count) * 60
        let remainder = max(0, cooldownTime - completedCooldown)
        if remainder > 0 {
            sets.append(SetRecord(setNumber: restSetCounter + 1, setTime: remainder,
                                  heartRate: currentHeartRate?(), totalTime: frozenElapsedTime + cooldownTime,
                                  isRestSet: true, isCooldownSet: true, associatedWorkSetNumber: nil))
        }
        // An early stop does not constitute a two-minute recovery measurement.
        finishWorkout(at: cooldownPauseStartTime ?? nowProvider())
        persistCurrentSession()
    }
    
    func reset() {
        stopTimer()
        stopCooldownTimer()
        stopPresetStartCountdownTimer()
        state = .idle
        elapsedTime = 0
        currentSetTime = 0
        pauseStartTime = nil
        startTime = nil
        pauses.removeAll()
        workoutStartedAt = nil
        workoutEndedAt = nil
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
        updateCaloriesEstimate()
        // Reset preset state
        activePreset = nil
        presetPhase = .work
        presetCurrentSet = 0
        presetPhaseTimeRemaining = 0
        isPresetPrestartCountdownActive = false
        presetPhaseStartTime = nil
        presetPhasePausedTime = 0
        presetStartCountdownRemainingOnPause = 0
        defaultWorkoutTitle = nil
        persistCurrentSession()
    }

    // MARK: - Preset Mode

    func loadPreset(_ preset: TimerPreset) {
        guard preset.workDuration.isFinite, preset.workDuration > 0,
              preset.restDuration.isFinite, preset.restDuration >= 0,
              (1...1000).contains(preset.numberOfSets) else { return }
        reset()
        activePreset = preset
        presetPhase = .work
        presetCurrentSet = 1
        presetPhaseTimeRemaining = preset.workDuration
        persistCurrentSession()
    }

    func clearPreset() {
        if isPresetPrestartCountdownActive && startTime == nil {
            state = .idle
        }
        stopPresetStartCountdownTimer()
        isPresetPrestartCountdownActive = false
        activePreset = nil
        presetPhase = .work
        presetCurrentSet = 0
        presetPhaseTimeRemaining = 0
        presetPhaseStartTime = nil
        presetPhasePausedTime = 0
        presetStartCountdownRemainingOnPause = 0
        if sets.isEmpty {
            defaultWorkoutTitle = nil
        }
        persistCurrentSession()
    }

    func startPreset() {
        guard let preset = activePreset, state == .idle || state == .paused else { return }

        if state == .idle {
            AppAnalytics.signal(.workoutStart)
            stopTimer()
            stopPresetStartCountdownTimer()
            defaultWorkoutTitle = resolvedPresetName(for: preset)
            startTime = nil
            elapsedTime = 0
            currentSetTime = 0
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
            presetPhaseTimeRemaining = presetStartCountdownDuration
            isPresetPrestartCountdownActive = true
            presetPhaseStartTime = nil
            presetPhasePausedTime = 0
            presetStartCountdownRemainingOnPause = presetStartCountdownDuration
            state = .running
            if presetStartCountdownDuration > 0 {
                startPresetStartCountdownTimer(remaining: presetStartCountdownDuration)
            } else {
                completePresetPrestartCountdownAndStartWork()
            }
            persistCurrentSession()
            return
        } else if state == .paused {
            if isPresetPrestartCountdownActive {
                self.pauseStartTime = nil
                state = .running
                if presetStartCountdownRemainingOnPause > 0 {
                    startPresetStartCountdownTimer(remaining: presetStartCountdownRemainingOnPause)
                } else {
                    completePresetPrestartCountdownAndStartWork()
                }
                persistCurrentSession()
                return
            }

            // Resume from paused state
            if let pauseStartTime = pauseStartTime {
                let resumedAt = nowProvider()
                pauses.append(WorkoutPause(start: pauseStartTime, end: resumedAt))
                let pauseDuration = resumedAt.timeIntervalSince(pauseStartTime)
                startTime = (startTime ?? nowProvider()).addingTimeInterval(pauseDuration)
                presetPhaseStartTime = (presetPhaseStartTime ?? nowProvider()).addingTimeInterval(pauseDuration)
                self.pauseStartTime = nil
            }
        }

        state = .running
        startPresetTimer()
        persistCurrentSession()
    }

    func pausePreset() {
        refreshTiming()
        guard state == .running, isPresetMode else { return }
        state = .paused

        if isPresetPrestartCountdownActive {
            if let countdownEndTime = presetStartCountdownEndTime {
                presetStartCountdownRemainingOnPause = max(0, countdownEndTime.timeIntervalSince(nowProvider()))
            } else {
                presetStartCountdownRemainingOnPause = max(0, presetPhaseTimeRemaining)
            }
            stopPresetStartCountdownTimer()
            pauseStartTime = nowProvider()
            persistCurrentSession()
            return
        }

        stopTimer()
        pauseStartTime = nowProvider()
        // Save how much time has elapsed in current phase
        if let phaseStart = presetPhaseStartTime {
            presetPhasePausedTime = nowProvider().timeIntervalSince(phaseStart)
        }
        persistCurrentSession()
    }

    func endPreset() {
        refreshTiming()
        guard let preset = activePreset, state == .running || state == .paused else { return }
        if isPresetPrestartCountdownActive { clearPreset(); return }
        if presetPhase == .work { capturePresetSet() } else { capturePresetRestSet() }
        frozenElapsedTime = elapsedTime
        stopTimer()
        if preset.includeCooldown {
            beginCooldown(at: nowProvider(), heartRate: currentHeartRate?())
        } else {
            finishWorkout(at: pauseStartTime ?? nowProvider())
        }
        persistCurrentSession()
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
        refreshTiming()
        guard isPresetMode, state == .running || state == .paused else { return }
        if isPresetPrestartCountdownActive { clearPreset(); return }
        if presetPhase == .work { capturePresetSet() } else { capturePresetRestSet() }
        frozenElapsedTime = elapsedTime
        finishWorkout(at: pauseStartTime ?? nowProvider())
        persistCurrentSession()
    }

    private func resolvedPresetName(for preset: TimerPreset) -> String {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom Preset" : trimmed
    }

    private func startPresetStartCountdownTimer(remaining: TimeInterval) {
        stopPresetStartCountdownTimer()
        presetStartCountdownRemainingOnPause = max(0, remaining)
        presetStartCountdownEndTime = nowProvider().addingTimeInterval(max(0, remaining))
        presetPhaseTimeRemaining = max(0, remaining)
        presetStartCountdownTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshTiming()
        }
        RunLoop.main.add(presetStartCountdownTimer!, forMode: .common)
        refreshTiming()
    }

    private func stopPresetStartCountdownTimer() {
        presetStartCountdownTimer?.invalidate()
        presetStartCountdownTimer = nil
        presetStartCountdownEndTime = nil
    }

    private func completePresetPrestartCountdownAndStartWork() {
        guard isPresetPrestartCountdownActive else { return }
        completePersistedPresetCountdown(at: nowProvider())
        startPresetTimer()
        refreshTiming()
        persistCurrentSession()
    }

    private func startPresetTimer() {
        startTimer()
    }

    private func playPhaseEndSound() {
        guard let preset = activePreset, preset.playSound else { return }
        let deactivationToken = UUID()
        audioSessionDeactivationToken = deactivationToken

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
        playBells(count: bellCount, deactivationToken: deactivationToken)
    }

    static func bellCount(for phase: PresetPhase) -> Int {
        switch phase {
        case .work, .rest, .cooldown:
            return 1
        }
    }

    private func playBells(count: Int, current: Int = 0, deactivationToken: UUID) {
        guard current < count else { return }

        let soundURL = URL(fileURLWithPath: "/System/Library/Audio/UISounds/sms-received1.caf")
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.prepareToPlay()
            let didStartPlayback = audioPlayer?.play() ?? false

            if current + 1 < count {
                // Schedule next bell after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.playBells(count: count, current: current + 1, deactivationToken: deactivationToken)
                }
            } else if didStartPlayback {
                scheduleAudioSessionDeactivation(
                    after: Self.audioSessionDeactivationDelay(soundDuration: audioPlayer?.duration),
                    token: deactivationToken
                )
            } else {
                deactivateAudioSession(token: deactivationToken)
            }
        } catch {
            AudioServicesPlaySystemSound(1013)
            scheduleAudioSessionDeactivation(after: Self.audioSessionDeactivationDelay(soundDuration: nil), token: deactivationToken)
        }
    }

    static func audioSessionDeactivationDelay(soundDuration: TimeInterval?) -> TimeInterval {
        max((soundDuration ?? 0.8) + 0.2, 0.5)
    }

    private func scheduleAudioSessionDeactivation(after delay: TimeInterval, token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deactivateAudioSession(token: token)
        }
    }

    private func deactivateAudioSession(token: UUID) {
        guard audioSessionDeactivationToken == token else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate interval audio session: \(error.localizedDescription)")
        }
    }

    private func advancePresetPhase() {
        guard let preset = activePreset, let phaseStart = presetPhaseStartTime else { return }
        let duration = presetPhase == .work ? preset.workDuration : preset.restDuration
        let boundary = phaseStart.addingTimeInterval(duration)
        let timely = abs(nowProvider().timeIntervalSince(boundary)) <= 1
        let bpm = timely ? currentHeartRate?() : heartRate(at: lastSetEndTime + duration)
        if timely { playPhaseEndSound() }
        if presetPhase == .work {
            capturePresetSet(duration: duration, boundaryHeartRate: bpm)
            if presetCurrentSet == preset.numberOfSets {
                // This set was already captured. Do not call the manual end action.
                elapsedTime = lastSetEndTime
                frozenElapsedTime = elapsedTime
                currentSetTime = 0
                stopTimer()
                if preset.includeCooldown {
                    beginCooldown(at: boundary, heartRate: bpm)
                } else {
                    finishWorkout(at: boundary)
                }
                return
            }
            presetPhase = .rest
            isTimingRestSet = true
            currentRestAssociatedWorkSetNumber = presetCurrentSet
            sets.append(SetRecord(setNumber: presetCurrentSet, setTime: 0, heartRate: nil,
                                  totalTime: lastSetEndTime, isRestSet: true, isCooldownSet: false,
                                  associatedWorkSetNumber: presetCurrentSet))
        } else {
            capturePresetRestSet(duration: duration, boundaryHeartRate: bpm)
            presetCurrentSet += 1
            presetPhase = .work
            isTimingRestSet = false
            currentRestAssociatedWorkSetNumber = nil
        }
        presetPhaseStartTime = boundary
        presetPhaseTimeRemaining = presetPhase == .work ? preset.workDuration : preset.restDuration
    }


    private func capturePresetSet(duration: TimeInterval? = nil, boundaryHeartRate: Int? = nil) {
        guard let preset = activePreset else { return }

        // Use exact preset duration instead of actual elapsed time to avoid drift
        let segmentTime = duration ?? min(preset.workDuration, max(0, elapsedTime - lastSetEndTime))
        let heartRate = duration == nil ? currentHeartRate?() : boundaryHeartRate

        setCounter += 1

        // Calculate total time based on completed sets
        let previousTotalTime = lastSetEndTime
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

    private func capturePresetRestSet(duration: TimeInterval? = nil, boundaryHeartRate: Int? = nil) {
        guard let preset = activePreset else { return }

        // Use exact preset duration instead of actual elapsed time to avoid drift
        let segmentTime = duration ?? min(preset.restDuration, max(0, elapsedTime - lastSetEndTime))
        let heartRate = duration == nil ? currentHeartRate?() : boundaryHeartRate

        // Calculate total time based on last set
        let previousTotalTime = lastSetEndTime
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
        startCooldownTimer()
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshTiming() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func observeHeartRate(from manager: HeartRateBluetoothManager) {
        heartRateCancellable = manager.heartRateMeasurements.sink { [weak self] sample in
            self?.recordHeartRateSample(sample)
        }
    }

    func recordHeartRateSample(_ sample: HeartRateSample) {
        refreshTiming()
        guard (state == .running && !isPresetPrestartCountdownActive) || state == .cooldown,
              sample.value > 0, sample.sensorContactStatus != .notDetected else { return }
        let time = state == .cooldown ? frozenElapsedTime + cooldownTime : elapsedTime
        heartRateSamples.append(HeartRateSample(value: sample.value, timestamp: nowProvider(),
                                               workoutTime: time, sensorContactStatus: sample.sensorContactStatus))
        updateCaloriesEstimate()
        // Persist received data while backgrounded, not just the state at background entry.
        persistCurrentSession()
    }

    private func samples(from start: TimeInterval, through end: TimeInterval) -> [HeartRateSample] {
        heartRateSamples.filter {
            guard let time = $0.workoutTime else { return false }
            return time > start && time <= end && $0.value > 0
        }
    }

    private func heartRate(at time: TimeInterval) -> Int? {
        heartRateSamples.last {
            guard let sampleTime = $0.workoutTime else { return false }
            return sampleTime <= time && time - sampleTime <= 1
        }?.value
    }

    /// Reconcile every elapsed boundary before handling input, foregrounding, or samples.
    func refreshTiming() {
        guard !isRefreshingTiming else { return }
        isRefreshingTiming = true
        defer { isRefreshingTiming = false }
        let now = nowProvider()
        let wasPrestart = isPresetPrestartCountdownActive
        if state != .paused || !isPresetPrestartCountdownActive {
            syncDerivedState(referenceDate: now, allowPresetCountdownCompletion: true)
        }
        if wasPrestart && !isPresetPrestartCountdownActive { startPresetTimer() }
        var advancedPhase = false
        while state == .running && !isPresetPrestartCountdownActive,
              let preset = activePreset, let phaseStart = presetPhaseStartTime {
            let duration = presetPhase == .work ? preset.workDuration : preset.restDuration
            guard duration.isFinite && duration >= 0,
                  now.timeIntervalSince(phaseStart) >= duration else { break }
            advancePresetPhase()
            advancedPhase = true
        }
        syncDerivedState(referenceDate: now, allowPresetCountdownCompletion: false)
        if state == .cooldown {
            for minute in 1...2 where cooldownTime >= Double(minute * 60) {
                captureCooldownHeartRate(minute: minute)
            }
            if cooldownTime >= 120, let start = cooldownStartTime {
                cooldownTime = 120
                currentSetTime = 120
                if abs(now.timeIntervalSince(start) - 120) <= 1 { playPhaseEndSound() }
                finishWorkout(at: start.addingTimeInterval(120))
                persistCurrentSession()
            }
        }
        if advancedPhase { persistCurrentSession() }
        updateLiveActivityElapsed()
    }

    private func beginCooldown(at date: Date, heartRate: Int?) {
        if state == .paused, let pauseStartTime {
            pauses.append(WorkoutPause(start: pauseStartTime, end: date))
        }
        pauseStartTime = nil
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        cooldownStartHeartRate = heartRate
        cooldownEndHeartRate = nil
        cooldownStartTime = date
        restStartTime = date
        cooldownTime = 0
        currentSetTime = 0
        cooldownPauseStartTime = nil
        if isPresetMode { presetPhase = .cooldown }
        state = .cooldown
        startCooldownTimer()
    }

    private func finishWorkout(at date: Date) {
        stopTimer()
        stopCooldownTimer()
        stopPresetStartCountdownTimer()
        isTimingRestSet = false
        currentRestAssociatedWorkSetNumber = nil
        workoutEndedAt = date
        state = .idle
        activePreset = nil
        finalizeCaloriesSession(endAt: date)
    }

    private func updateLiveActivityElapsed(force: Bool = false) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            let elapsed: Int?
            switch state {
            case .running, .paused:
                elapsed = Int(elapsedTime)
            case .cooldown, .cooldownPaused:
                elapsed = Int(frozenElapsedTime + cooldownTime)
            case .idle:
                elapsed = nil
            }

            if !force, elapsed == lastLiveActivityElapsedSeconds {
                return
            }

            lastLiveActivityElapsedSeconds = elapsed
            let advancing = state == .running && !isPresetPrestartCountdownActive || state == .cooldown
            let elapsedValue = state == .cooldown ? frozenElapsedTime + cooldownTime : elapsedTime
            let reference = advancing ? Date().addingTimeInterval(-elapsedValue) : nil
            let totalLimit: TimeInterval? = state == .cooldown ? frozenElapsedTime + 120 : activePreset?.totalDuration
            let endDate = reference.flatMap { reference in totalLimit.map { reference.addingTimeInterval($0) } }
            Task { @MainActor in
                HeartRateActivityController.shared.updateTimer(elapsedSeconds: elapsed, isRunning: elapsed != nil,
                                                               referenceDate: reference, endDate: endDate)
            }
        }
        #endif
    }

    private var calorieSamples: [HeartRateSample] {
        // Calories use the active timeline too; pauses must not become exercise.
        return heartRateSamples.map { sample in
            HeartRateSample(value: sample.value,
                            timestamp: Date(timeIntervalSince1970: sample.workoutTime ?? 0),
                            workoutTime: sample.workoutTime, sensorContactStatus: sample.sensorContactStatus)
        }
    }

    private func updateCaloriesEstimate() {
        let samples = calorieSamples
        let profile = UserEnergyProfileStore.currentProfile()
        caloriesQueue.async { [weak self] in
            let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
            DispatchQueue.main.async {
                self?.caloriesStatus = status
            }
        }
    }

    private func finalizeCaloriesSession(endAt: Date = Date()) {
        guard let startTime = startTime else { return }
        let profile = UserEnergyProfileStore.currentProfile()
        let status = CaloriesEstimator.estimate(samples: calorieSamples, profile: profile)
        guard case let .available(estimate) = status else { return }

        let session = CaloriesSession(
            startAt: startTime,
            endAt: endAt,
            totalKcal: estimate.totalKcal,
            activeKcal: estimate.activeKcal,
            methodUsed: estimate.method.rawValue,
            confidence: estimate.confidence
        )
        CaloriesSessionStore.shared.save(session)
    }
    
    private func startCooldownTimer() {
        stopCooldownTimer()
        guard state == .cooldown else { return }
        cooldownTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshTiming()
        }
        RunLoop.main.add(cooldownTimer!, forMode: .common)
        refreshTiming()
    }
    
    private func stopCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
    }
    
    private func captureCooldownHeartRate(minute: Int) {
        guard let cooldownStartTime,
              !sets.contains(where: { $0.isCooldownSet && $0.setNumber == minute }) else { return }
        let boundary = TimeInterval(minute * 60)
        let total = frozenElapsedTime + boundary
        let timely = abs(nowProvider().timeIntervalSince(cooldownStartTime) - boundary) <= 1
        let heartRate = timely ? currentHeartRate?() : heartRate(at: total)
        if minute == 2 { cooldownEndHeartRate = heartRate }
        restSetCounter = minute
        sets.append(SetRecord(setNumber: minute, setTime: 60, heartRate: heartRate,
                              totalTime: total, isRestSet: true, isCooldownSet: true,
                              associatedWorkSetNumber: nil))
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
        var durations: [HeartRateZone: TimeInterval] = [:]
        for (sample, duration) in weightedSamples(from: 0, through: resolvedTotalTime()) {
            if let zone = HeartRateZone.zone(for: sample.value, config: config) {
                durations[zone, default: 0] += duration
            }
        }
        return HeartRateZone.allCases.map { ZoneTimeData(zone: $0, duration: durations[$0, default: 0]) }
    }

    private func weightedSamples(from start: TimeInterval, through end: TimeInterval) -> [(HeartRateSample, TimeInterval)] {
        heartRateSamples.enumerated().compactMap { index, sample in
            guard let time = sample.workoutTime else { return nil }
            let next = index + 1 < heartRateSamples.count ? (heartRateSamples[index + 1].workoutTime ?? end) : end
            // A received reading can represent at most the same 3-second freshness
            // window used for live BPM. Never extend it through a long data gap.
            let stop = min(end, next, time + HeartRateBluetoothManager.defaultHeartRateFreshnessInterval)
            let duration = max(0, stop - max(start, time))
            return duration > 0 ? (sample, duration) : nil
        }
    }

    private func averageBPM(from start: TimeInterval, through end: TimeInterval) -> Int? {
        let values = weightedSamples(from: start, through: end)
        let duration = values.reduce(0) { $0 + $1.1 }
        guard duration > 0 else { return samples(from: start, through: end).last?.value }
        let total = values.reduce(0.0) { $0 + Double($1.0.value) * $1.1 }
        return Int((total / duration).rounded())
    }

    func workoutRecord(
        zoneConfig: HeartRateZoneConfig,
        workoutId: UUID? = nil,
        title: String? = nil,
        notes: String? = nil
    ) -> WorkoutRecord? {
        refreshTiming()
        guard let startTime = startTime else { return nil }
        let totalTime = resolvedTotalTime()
        let actualStart = workoutStartedAt ?? startTime
        let endTime = workoutEndedAt ?? nowProvider()
        let notesValue = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notesValue?.isEmpty == false ? notesValue : nil

        let zoneSummaries = timeInZones(config: zoneConfig)
            .filter { $0.duration > 0 }
            .map { WorkoutZoneSummary(id: UUID(), zone: $0.zone.rawValue, duration: $0.duration) }

        let sampleSummaries = heartRateSamples.map { sample in
            WorkoutHeartRateSample(timestamp: sample.timestamp, bpm: sample.value, workoutTime: sample.workoutTime)
        }

        let setSummaries = sets.map { set in
            WorkoutSetSummary(
                id: UUID(),
                label: displayLabel(for: set),
                setTime: set.setTime,
                totalTime: set.totalTime,
                isRestSet: set.isRestSet,
                isCooldownSet: set.isCooldownSet,
                associatedWorkSetNumber: set.associatedWorkSetNumber,
                avgBpm: avgBPMForSet(set),
                minBpm: minBPMForSet(set),
                maxBpm: maxBPMForSet(set)
            )
        }

        let caloriesTotal: Double?
        let caloriesActive: Double?
        switch caloriesStatus {
        case .available(let estimate):
            caloriesTotal = estimate.totalKcal
            caloriesActive = estimate.activeKcal
        default:
            caloriesTotal = nil
            caloriesActive = nil
        }

        return WorkoutRecord(
            id: workoutId ?? UUID(),
            schemaVersion: WorkoutRecord.schemaVersion,
            title: title,
            startAt: actualStart,
            endAt: endTime,
            durationSeconds: totalTime,
            avgHr: avgHeartRate,
            maxHr: maxHeartRate,
            minHr: minHeartRate,
            hrv: nil,
            hrr: heartRateRecovery,
            caloriesTotal: caloriesTotal,
            caloriesActive: caloriesActive,
            hrSamples: sampleSummaries,
            zones: zoneSummaries,
            sets: setSummaries,
            notes: normalizedNotes,
            source: "phone",
            appVersion: appVersionString(),
            healthKitWorkoutUUID: nil,
            healthKitSyncedAt: nil,
            healthKitLastError: nil,
            createdAt: nowProvider(),
            updatedAt: nowProvider(),
            pauses: pauses
        )
    }

    // MARK: - Sharing

    func workoutSummaryText(totalTime: TimeInterval, zoneConfig: HeartRateZoneConfig) -> String {
        var lines: [String] = []
        let workSets = sets.filter { !$0.isRestSet && !$0.isCooldownSet }
        let restSets = sets.filter { $0.isRestSet && !$0.isCooldownSet }
        let cooldownSets = sets.filter { $0.isCooldownSet }
        let zones = timeInZones(config: zoneConfig)
        let totalZoneTime = zones.reduce(0) { $0 + $1.duration }
        let caloriesStatus = CaloriesEstimator.estimate(samples: calorieSamples, profile: UserEnergyProfileStore.currentProfile())

        lines.append("🏁 Workout Summary")
        lines.append("")
        if let preset = activePreset {
            let presetName = preset.name.isEmpty ? "Custom Preset" : preset.name
            lines.append("🎯 Preset: \(presetName) (\(formatDuration(preset.workDuration, showTenths: false)) work / \(formatDuration(preset.restDuration, showTenths: false)) rest x \(preset.numberOfSets), cooldown \(preset.includeCooldown ? "on" : "off"))")
        }
        lines.append("⏱ Total time: \(formatDuration(totalTime, showTenths: false))")
        lines.append("🧱 Sets: Work \(workSets.count) • Rest \(restSets.count) • Cooldown \(cooldownSets.count)")

        if let avgSetTime = avgSetTime {
            lines.append("💪 Avg work set: \(formatDuration(avgSetTime, showTenths: false))")
        }
        if let avgRestTime = avgRestTime {
            lines.append("🧘 Avg rest: \(formatDuration(avgRestTime, showTenths: false))")
        }

        let avgBpmText = formattedHeartRate(avgHeartRate)
        let minBpmText = formattedHeartRate(minHeartRate)
        let maxBpmText = formattedHeartRate(maxHeartRate)
        lines.append("❤️ Avg BPM: \(avgBpmText) • Min \(minBpmText) • Max \(maxBpmText)")
        if let recovery = heartRateRecovery {
            lines.append("🧊 HRR (2 min): \(recovery)")
        }
        switch caloriesStatus {
        case .available(let estimate):
            let total = Int(round(estimate.totalKcal))
            let active = Int(round(estimate.activeKcal))
            lines.append("🔥 Calories: \(total) (active \(active))")
        case .insufficient(let remaining):
            lines.append("🔥 Calories: waiting \(formatWaitSeconds(remaining))")
        case .disabled:
            lines.append("🔥 Calories: disabled (missing profile fields)")
        }

        if totalZoneTime > 0 {
            let zoneSummary = zones.map { zoneData in
                "\(zoneData.zone.displayName) \(formatDuration(zoneData.duration, showTenths: false))"
            }.joined(separator: ", ")
            lines.append("🗺 Zones: \(zoneSummary)")
        }

        return lines.joined(separator: "\n")
    }

    func workoutDetailedText(totalTime: TimeInterval, zoneConfig: HeartRateZoneConfig) -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        let workSets = sets.filter { !$0.isRestSet && !$0.isCooldownSet }
        let restSets = sets.filter { $0.isRestSet && !$0.isCooldownSet }
        let cooldownSets = sets.filter { $0.isCooldownSet }
        let workoutTime = frozenElapsedTime > 0 ? frozenElapsedTime : totalTime
        let zones = timeInZones(config: zoneConfig)
        let totalZoneTime = zones.reduce(0) { $0 + $1.duration }
        let caloriesStatus = CaloriesEstimator.estimate(samples: calorieSamples, profile: UserEnergyProfileStore.currentProfile())

        lines.append("BPM Workout Detail Export")
        lines.append("Context:")
        lines.append("- App: BPM (iOS heart-rate app).")
        lines.append("- Heart rate samples: received Bluetooth measurements; values are bpm. Gaps are not filled.")
        lines.append("- Zones: derived from max HR (default 190) or user config; zone is chosen by lower-bound thresholds.")
        lines.append("- Sets: work/rest/cooldown; total time includes workout + cooldown; workout time is pre-cooldown.")
        lines.append("- HRR (2 min): HR at cooldown start minus HR after 2 minutes of cooldown.")
        lines.append("- Calories: HR-only estimate using profile inputs; no accelerometer.")
        lines.append("- Durations are formatted as m:ss(.t) or h:mm:ss.")
        lines.append("")
        lines.append("Exported: \(formatter.string(from: nowProvider()))")
        if let startTime = workoutStartedAt ?? startTime {
            lines.append("Start: \(formatter.string(from: startTime))")
            let endTime = workoutEndedAt ?? nowProvider()
            lines.append("End: \(formatter.string(from: endTime))")
        } else {
            lines.append("Start: unknown")
        }
        lines.append("Total time: \(formatDuration(totalTime, showTenths: false))")
        lines.append("Workout time (pre-cooldown): \(formatDuration(workoutTime, showTenths: false))")
        if cooldownTime > 0 {
            lines.append("Cooldown time: \(formatDuration(cooldownTime, showTenths: false))")
        }
        lines.append("State: \(stateDescription(state))")
        lines.append("Preset mode: \(isPresetMode ? "yes" : "no")")

        if let preset = activePreset {
            let presetName = preset.name.isEmpty ? "Custom Preset" : preset.name
            lines.append("Preset: \(presetName)")
            lines.append("Preset work duration: \(formatDuration(preset.workDuration, showTenths: false))")
            lines.append("Preset rest duration: \(formatDuration(preset.restDuration, showTenths: false))")
            lines.append("Preset sets: \(preset.numberOfSets)")
            lines.append("Preset cooldown: \(preset.includeCooldown ? "on" : "off")")
            lines.append("Preset sound: \(preset.playSound ? "on" : "off")")
        }

        lines.append("Work sets: \(workSets.count)")
        lines.append("Rest sets: \(restSets.count)")
        lines.append("Cooldown sets: \(cooldownSets.count)")

        lines.append("Average work set: \(avgSetTime.map { formatDuration($0, showTenths: false) } ?? "n/a")")
        lines.append("Average rest: \(avgRestTime.map { formatDuration($0, showTenths: false) } ?? "n/a")")
        lines.append("Avg BPM: \(formattedHeartRate(avgHeartRate))")
        lines.append("Min BPM: \(formattedHeartRate(minHeartRate))")
        lines.append("Max BPM: \(formattedHeartRate(maxHeartRate))")
        switch caloriesStatus {
        case .available(let estimate):
            lines.append("Calories total (kcal): \(String(format: "%.1f", estimate.totalKcal))")
            lines.append("Calories active (kcal): \(String(format: "%.1f", estimate.activeKcal))")
            lines.append("Calories method: \(estimate.method.rawValue)")
            lines.append("Calories confidence: \(String(format: "%.2f", estimate.confidence))")
            lines.append("Calories HR samples: \(estimate.hrSampleCount), gaps: \(estimate.gapCount)")
        case .insufficient(let remaining):
            lines.append("Calories: waiting \(formatWaitSeconds(remaining))")
        case .disabled:
            lines.append("Calories: disabled (missing profile fields)")
        }
        lines.append("Cooldown start BPM: \(formattedHeartRate(cooldownStartHeartRate))")
        lines.append("Cooldown end BPM: \(formattedHeartRate(cooldownEndHeartRate))")
        lines.append("HRR (2 min): \(heartRateRecovery.map(String.init) ?? "n/a")")

        lines.append("Sets:")
        if sets.isEmpty {
            lines.append("  (none)")
        } else {
            for set in sets {
                let type = set.isCooldownSet ? "cooldown" : (set.isRestSet ? "rest" : "work")
                let avgBPM = avgBPMForSet(set)
                let minBPM = minBPMForSet(set)
                let maxBPM = maxBPMForSet(set)
                let label = displayLabel(for: set)
                let setTime = formatDuration(set.setTime, showTenths: false)
                let totalTimeValue = formatDuration(set.totalTime, showTenths: false)
                let associatedWorkSet = set.associatedWorkSetNumber.map(String.init) ?? "n/a"

                lines.append("  \(label) [\(type)] time=\(setTime) total=\(totalTimeValue) avgBPM=\(formattedHeartRate(avgBPM)) minBPM=\(formattedHeartRate(minBPM)) maxBPM=\(formattedHeartRate(maxBPM)) heartRate=\(formattedHeartRate(set.heartRate)) associatedWorkSet=\(associatedWorkSet)")
            }
        }

        lines.append("Time in zones:")
        if totalZoneTime == 0 {
            lines.append("  (no zone data)")
        } else {
            for zoneData in zones {
                let percentage = totalZoneTime > 0 ? (zoneData.duration / totalZoneTime) : 0
                lines.append("  \(zoneData.zone.fullName) (\(zoneData.zone.percentageRange)): \(formatDuration(zoneData.duration, showTenths: false)) (\(String(format: "%.1f", percentage * 100))%)")
            }
        }

        lines.append("Heart rate samples (timestamp,workoutTimeSeconds,bpm):")
        if heartRateSamples.isEmpty {
            lines.append("  (none)")
        } else {
            for sample in heartRateSamples {
                let timestamp = formatter.string(from: sample.timestamp)
                let workoutTimeValue = sample.workoutTime.map { String(format: "%.1f", $0) } ?? "n/a"
                lines.append("  \(timestamp),\(workoutTimeValue),\(sample.value)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formattedHeartRate(_ value: Int?) -> String {
        value.map(String.init) ?? "n/a"
    }

    private func resolvedTotalTime() -> TimeInterval {
        max(elapsedTime, frozenElapsedTime + cooldownTime, sets.last?.totalTime ?? 0)
    }

    private func formatWaitSeconds(_ remaining: TimeInterval) -> String {
        let clamped = max(0, remaining)
        let totalSeconds = Int(ceil(clamped))
        return "\(totalSeconds)s"
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private func formatDuration(_ time: TimeInterval, showTenths: Bool = true) -> String {
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let tenths = Int((time.truncatingRemainder(dividingBy: 1)) * 10)

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if !showTenths || minutes >= 10 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%d:%02d.%d", minutes, seconds, tenths)
        }
    }

    private func stateDescription(_ state: TimerState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .running:
            return "running"
        case .paused:
            return "paused"
        case .cooldown:
            return "cooldown"
        case .cooldownPaused:
            return "cooldownPaused"
        }
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
        if let didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
        }
        if let willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
        timer?.invalidate()
        cooldownTimer?.invalidate()
    }
}
