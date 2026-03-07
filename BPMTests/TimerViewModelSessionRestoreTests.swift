import Testing
import Foundation
@testable import BPM

struct TimerViewModelSessionRestoreTests {
    @Test @MainActor
    func restoresRunningWorkoutFromPersistedSession() {
        let store = makeStore()
        defer { store.clear() }

        let now = Date()
        store.save(
            snapshot(
                state: .running,
                elapsedTime: 35,
                currentSetTime: 25,
                sets: [
                    PersistedSetRecord(
                        setNumber: 1,
                        setTime: 10,
                        heartRate: 145,
                        totalTime: 10,
                        isRestSet: false,
                        isCooldownSet: false,
                        associatedWorkSetNumber: nil
                    )
                ],
                startTime: now.addingTimeInterval(-35),
                lastSetEndTime: 10
            )
        )

        let viewModel = TimerViewModel(
            presetStartCountdownDuration: 0,
            sessionStore: store,
            nowProvider: { now }
        )

        #expect(viewModel.state == .running)
        #expect(viewModel.hasRestorableSession)
        #expect(viewModel.sets.count == 1)
        #expect(abs(viewModel.elapsedTime - 35) < 0.25)
        #expect(abs(viewModel.currentSetTime - 25) < 0.25)

        viewModel.reset()
    }

    @Test @MainActor
    func restoresCooldownWorkoutFromPersistedSession() {
        let store = makeStore()
        defer { store.clear() }

        let now = Date()
        store.save(
            snapshot(
                state: .cooldown,
                elapsedTime: 120,
                currentSetTime: 30,
                sets: [
                    PersistedSetRecord(
                        setNumber: 1,
                        setTime: 120,
                        heartRate: 150,
                        totalTime: 120,
                        isRestSet: false,
                        isCooldownSet: false,
                        associatedWorkSetNumber: nil
                    )
                ],
                cooldownTime: 30,
                frozenElapsedTime: 120,
                startTime: now.addingTimeInterval(-150),
                cooldownStartTime: now.addingTimeInterval(-30),
                lastSetEndTime: 120,
                restStartTime: now.addingTimeInterval(-30)
            )
        )

        let viewModel = TimerViewModel(
            presetStartCountdownDuration: 0,
            sessionStore: store,
            nowProvider: { now }
        )

        #expect(viewModel.state == .cooldown)
        #expect(abs(viewModel.cooldownTime - 30) < 0.25)
        #expect(abs(viewModel.currentSetTime - 30) < 0.25)
        #expect(viewModel.frozenElapsedTime == 120)

        viewModel.reset()
    }

    @Test @MainActor
    func resetClearsPersistedSession() {
        let store = makeStore()
        defer { store.clear() }

        let viewModel = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: store)
        viewModel.start()

        #expect(store.load() != nil)

        viewModel.reset()

        #expect(store.load() == nil)

        let reloaded = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: store)
        #expect(!reloaded.hasRestorableSession)
    }

    private func makeStore() -> ActiveWorkoutSessionStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-workout-session-\(UUID().uuidString).json")
        return ActiveWorkoutSessionStore(fileURL: fileURL)
    }

    private func snapshot(
        state: TimerState,
        elapsedTime: TimeInterval,
        currentSetTime: TimeInterval,
        sets: [PersistedSetRecord],
        cooldownTime: TimeInterval = 0,
        frozenElapsedTime: TimeInterval = 0,
        startTime: Date?,
        pauseStartTime: Date? = nil,
        cooldownStartTime: Date? = nil,
        cooldownPauseStartTime: Date? = nil,
        lastSetEndTime: TimeInterval,
        restStartTime: Date? = nil
    ) -> ActiveWorkoutSessionSnapshot {
        ActiveWorkoutSessionSnapshot(
            schemaVersion: ActiveWorkoutSessionSnapshot.currentSchemaVersion,
            state: state,
            elapsedTime: elapsedTime,
            currentSetTime: currentSetTime,
            sets: sets,
            cooldownTime: cooldownTime,
            frozenElapsedTime: frozenElapsedTime,
            isTimingRestSet: false,
            activePreset: nil,
            presetPhase: .work,
            presetCurrentSet: 0,
            presetPhaseTimeRemaining: 0,
            isPresetPrestartCountdownActive: false,
            defaultWorkoutTitle: nil,
            startTime: startTime,
            pauseStartTime: pauseStartTime,
            cooldownStartTime: cooldownStartTime,
            cooldownPauseStartTime: cooldownPauseStartTime,
            setCounter: sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count,
            restSetCounter: sets.filter(\.isRestSet).count,
            lastSetEndTime: lastSetEndTime,
            currentRestAssociatedWorkSetNumber: nil,
            restStartTime: restStartTime,
            heartRateSamples: [],
            cooldownStartHeartRate: nil,
            cooldownEndHeartRate: nil,
            presetPhaseStartTime: nil,
            presetStartCountdownRemainingOnPause: 0,
            presetStartCountdownEndTime: nil
        )
    }
}
