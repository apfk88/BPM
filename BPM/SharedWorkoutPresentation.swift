import CryptoKit
import Foundation

enum SharedWorkoutPresentation {
    static func snapshot(
        timer: TimerViewModel,
        screen: SharedWorkoutSnapshot.Screen,
        page: SharedWorkoutSnapshot.Page,
        heartRate: Int?,
        zoneConfig: HeartRateZoneConfig,
        primaryBPM: String,
        calories: String,
        allowsRemoteControl: Bool = true
    ) -> SharedWorkoutSnapshot {
        let isCooldown = timer.isInCooldownMode
        let isEmpty = timer.state == .idle && timer.sets.isEmpty
        let advancing = (timer.state == .running || timer.state == .cooldown) && !timer.isPresetPrestartCountdownActive
        let total = isCooldown || timer.isCompleted ? timer.frozenElapsedTime : timer.elapsedTime
        let setTime: TimeInterval
        if timer.isCompleted {
            setTime = timer.avgSetTime ?? 0
        } else if isCooldown || (timer.isPresetMode && timer.presetPhase == .cooldown) {
            setTime = timer.presetPhaseTimeRemaining > 0 ? timer.presetPhaseTimeRemaining : max(0, 120 - timer.currentSetTime)
        } else {
            setTime = timer.isPresetMode ? timer.presetPhaseTimeRemaining : timer.currentSetTime
        }
        let canWork = allowsRemoteControl && timer.state == .running && !timer.isPresetMode && !timer.isCompleted
        let zoneTimes = timer.timeInZones(config: zoneConfig)
        let topZone = zoneTimes.filter { $0.duration > 0 }.max { lhs, rhs in
            lhs.duration == rhs.duration ? lhs.zone.rawValue > rhs.zone.rawValue : lhs.duration < rhs.duration
        }?.zone
        let zone = timer.isCompleted ? topZone : heartRate.flatMap { HeartRateZone.zone(for: $0, config: zoneConfig) }
        let revisionSource = "\(timer.sharingWorkoutID):\(timer.sharingControlGeneration):\(timer.recoverableSessionID?.uuidString ?? "none")"
        let revision = SHA256.hash(data: Data(revisionSource.utf8)).map { String(format: "%02x", $0) }.joined()

        return SharedWorkoutSnapshot(
            workoutID: timer.sharingWorkoutID,
            controlRevision: revision,
            screen: screen,
            page: page,
            state: timer.state,
            isCompleted: timer.isCompleted,
            isPresetMode: timer.isPresetMode,
            canWork: canWork,
            canRest: canWork && !timer.isTimingRestSet,
            totalTime: total,
            setTime: setTime,
            totalTimeAdvances: advancing && !isCooldown,
            setTimeDirection: advancing ? (isCooldown || timer.isPresetMode ? -1 : 1) : 0,
            showTenths: max(timer.elapsedTime, timer.frozenElapsedTime + (isCooldown ? timer.currentSetTime : 0)) < 3600,
            isEmpty: isEmpty,
            avgWorkTime: timer.avgSetTime,
            avgBPM: timer.avgHeartRate,
            maxBPM: timer.maxHeartRate,
            minBPM: timer.minHeartRate,
            zone: zone?.rawValue,
            setNumber: setNumber(timer),
            calories: calories,
            primaryBPM: primaryBPM,
            rows: Array(rows(timer, heartRate: heartRate).suffix(2048)),
            chart: chartPoints(timer),
            segments: Array(timer.chartSegments().suffix(2048)).map {
                SharedWorkoutSnapshot.Segment(startTime: $0.startTime, endTime: $0.endTime, kind: segmentKind($0.type))
            },
            chartMaxTime: timer.chartMaxTime(),
            zones: zoneTimes.map { SharedWorkoutSnapshot.ZoneDuration(zone: $0.zone.rawValue, duration: $0.duration) },
            allowedActions: allowsRemoteControl ? allowedActions(for: timer) : [],
            activePreset: timer.activePreset,
            recoverableHistorySeconds: timer.recoverableSessionID.flatMap { timer.recoverableHistoryDuration(for: $0) }
        )
    }

    static func apply(
        _ command: SharedWorkoutCommand,
        to timer: TimerViewModel,
        current snapshot: SharedWorkoutSnapshot
    ) -> Bool {
        guard command.workoutID == snapshot.workoutID,
              command.controlRevision == snapshot.controlRevision,
              snapshot.permits(command.action),
              timer.sharingWorkoutID == snapshot.workoutID,
              allowedActions(for: timer).contains(command.action) else { return false }
        guard command.action == .loadPreset || command.preset == nil else { return false }
        switch command.action {
        case .work:
            timer.captureSet()
        case .rest:
            guard !timer.isTimingRestSet else { return false }
            timer.captureRestSet()
        case .start:
            if timer.isPresetMode { timer.startPreset() } else { timer.start() }
        case .startIncludingHistory:
            guard let sessionID = timer.recoverableSessionID else { return false }
            timer.start(includingPreviousMeasurementsFrom: sessionID)
        case .pause:
            if timer.state == .cooldown { timer.toggleCooldown() }
            else if timer.isPresetMode { timer.pausePreset() }
            else { timer.stop() }
        case .resume:
            if timer.isCompleted { timer.resumeEndedWorkout() }
            else if timer.state == .cooldownPaused { timer.toggleCooldown() }
            else if timer.isPresetMode { timer.startPreset() }
            else { timer.start() }
        case .end:
            timer.endWorkout()
        case .reset:
            timer.reset()
        case .cool:
            timer.captureSet()
            timer.end()
        case .loadPreset:
            guard let preset = command.preset, isValidSharedPreset(preset) else { return false }
            timer.loadPreset(preset)
        case .clearPreset:
            timer.clearPreset()
        }
        return true
    }

    static func allowedActions(for timer: TimerViewModel) -> [SharedWorkoutAction] {
        var actions: [SharedWorkoutAction] = []
        if timer.state == .running, !timer.isPresetMode, !timer.isCompleted {
            actions.append(.work)
            if !timer.isTimingRestSet { actions.append(.rest) }
        }
        if timer.state == .idle, !timer.isCompleted {
            actions += [.start, .loadPreset]
            if let sessionID = timer.recoverableSessionID, (timer.recoverableHistoryDuration(for: sessionID) ?? 0) > 0 {
                actions.append(.startIncludingHistory)
            }
            if timer.isPresetMode { actions.append(.clearPreset) }
        }
        if timer.state == .running || timer.state == .cooldown { actions.append(.pause) }
        if timer.state == .paused || timer.state == .cooldownPaused || timer.isCompleted { actions.append(.resume) }
        if timer.state != .idle { actions.append(.end) }
        if !timer.isPresetMode, timer.state == .running || timer.state == .paused { actions.append(.cool) }
        if timer.state != .idle || !timer.sets.isEmpty || timer.isPresetMode { actions.append(.reset) }
        return actions
    }

    static func isValidSharedPreset(_ preset: TimerPreset) -> Bool {
        !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && preset.name.count <= 80
            && preset.name.rangeOfCharacter(from: .controlCharacters) == nil
            && preset.workDuration.isFinite && preset.workDuration > 0 && preset.workDuration <= 86_400
            && preset.restDuration.isFinite && preset.restDuration >= 0 && preset.restDuration <= 86_400
            && (1...1000).contains(preset.numberOfSets)
            && preset.totalDuration.isFinite && preset.totalDuration <= 7 * 24 * 60 * 60
    }

    private static func setNumber(_ timer: TimerViewModel) -> String {
        let workSets = timer.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
        if timer.isCompleted { return String(workSets) }
        if timer.isInCooldownMode { return "C\(timer.sets.filter(\.isCooldownSet).count + 1)" }
        if timer.state == .running || timer.state == .paused {
            if timer.isTimingRestSet {
                return timer.sets.last(where: { $0.isRestSet && !$0.isCooldownSet }).map(timer.displayLabel) ?? "---"
            }
            return String(workSets + 1)
        }
        return timer.sets.last.map(timer.displayLabel) ?? "---"
    }

    private static func rows(_ timer: TimerViewModel, heartRate: Int?) -> [SharedWorkoutSnapshot.Row] {
        var result = timer.sets.map { set in
            SharedWorkoutSnapshot.Row(
                id: set.id.uuidString, label: timer.displayLabel(for: set),
                kind: set.isCooldownSet ? "cooldown" : (set.isRestSet ? "rest" : "work"),
                isActive: timer.isActiveRestSet(set), duration: timer.displaySetTime(for: set),
                totalTime: timer.displayTotalTime(for: set), avgBPM: timer.displayAvgBPM(for: set),
                maxBPM: timer.displayMaxBPM(for: set), minBPM: timer.displayMinBPM(for: set)
            )
        }
        if timer.state == .idle && timer.sets.isEmpty {
            if timer.isPresetMode {
                result += timer.presetPlaceholderSets.enumerated().map { placeholder($0.element, index: $0.offset, timer: timer) }
            } else {
                result.append(.init(id: "empty", label: "1", kind: "empty", isActive: false,
                                    duration: 0, totalTime: 0, avgBPM: nil, maxBPM: nil, minBPM: nil))
            }
        }
        if (timer.state == .running || timer.state == .paused) && !timer.isTimingRestSet {
            result.append(.init(
                id: "active", label: setNumber(timer), kind: "work", isActive: true,
                duration: timer.currentSetTime, totalTime: timer.elapsedTime,
                avgBPM: timer.avgBPMForCurrentSet(), maxBPM: timer.maxBPMForCurrentSet(), minBPM: timer.minBPMForCurrentSet()
            ))
        }
        if timer.isInCooldownMode {
            result.append(.init(
                id: "activeCooldown", label: setNumber(timer), kind: "cooldown", isActive: true,
                duration: timer.currentSetTime, totalTime: timer.frozenElapsedTime + timer.currentSetTime,
                avgBPM: heartRate, maxBPM: heartRate, minBPM: heartRate
            ))
            if !timer.sets.contains(where: \.isCooldownSet) {
                result.append(.init(id: "nextCooldown", label: "C2", kind: "placeholder", isActive: false,
                                    duration: 60, totalTime: timer.frozenElapsedTime + 120, avgBPM: nil, maxBPM: nil, minBPM: nil))
            }
        }
        if timer.isPresetMode && timer.state != .idle {
            let remaining = timer.remainingPresetPlaceholderSets.filter { !timer.isInCooldownMode || !$0.isCooldownSet }
            result += remaining.enumerated().map { placeholder($0.element, index: $0.offset, timer: timer) }
        }
        return result
    }

    private static func placeholder(_ set: SetRecord, index: Int, timer: TimerViewModel) -> SharedWorkoutSnapshot.Row {
        .init(id: "placeholder-\(index)", label: timer.displayLabel(for: set), kind: "placeholder", isActive: false,
              duration: set.setTime, totalTime: set.totalTime, avgBPM: nil, maxBPM: nil, minBPM: nil)
    }

    private static func segmentKind(_ type: TimerViewModel.ChartSegment.SegmentType) -> String {
        switch type {
        case .work: return "work"
        case .rest: return "rest"
        case .cooldown: return "cooldown"
        }
    }

    private static func chartPoints(_ timer: TimerViewModel) -> [SharedWorkoutSnapshot.ChartPoint] {
        let points = timer.chartDataPoints().map {
            SharedWorkoutSnapshot.ChartPoint(time: $0.time, bpm: $0.bpm, segment: $0.segment, validUntil: $0.validUntil)
        }
        return reducedChart(points, maxTime: timer.chartMaxTime())
    }

    /// Bound live payloads while retaining peaks, troughs, and signal gaps.
    /// Workout statistics and the saved recording always use the original samples.
    static func reducedChart(_ points: [SharedWorkoutSnapshot.ChartPoint], maxTime: TimeInterval) -> [SharedWorkoutSnapshot.ChartPoint] {
        guard points.count > 720, maxTime > 0 else { return points }
        struct Bucket: Hashable { let segment: Int; let index: Int }
        let buckets = Dictionary(grouping: points) {
            Bucket(segment: $0.segment, index: Int($0.time / maxTime * 180))
        }
        let retained = buckets.values.flatMap { bucket -> [SharedWorkoutSnapshot.ChartPoint] in
            let candidates = [bucket.first!, bucket.min { $0.bpm < $1.bpm }!,
                              bucket.max { $0.bpm < $1.bpm }!, bucket.last!]
            var seen = Set<Double>()
            return candidates.filter { seen.insert($0.time).inserted }
        }.sorted { $0.time < $1.time }
        return Array(retained.suffix(8192))
    }
}
