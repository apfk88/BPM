import Foundation
import Testing
@testable import BPM

struct TimerSoundRoutingTests {
    @Test @MainActor
    func countdownAndEveryPresetTransitionUseTheEnteringPhaseCue() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel(countdown: 5)
        defer { model.reset() }
        model.loadPreset(preset(sets: 3))
        model.startPreset()
        #expect(probe.cues.isEmpty)

        probe.seconds = 4.9
        model.refreshTiming()
        #expect(probe.cues.isEmpty)

        for boundary in [5.0, 15, 20, 30, 35, 45] {
            probe.seconds = boundary
            model.refreshTiming()
            model.refreshTiming()
        }

        #expect(probe.cues == [.workBegins, .restBegins, .workBegins, .restBegins, .workBegins, .workoutComplete])
        #expect(model.state == .idle)
        #expect(model.sets.map(\.setTime) == [10, 5, 10, 5, 10])
    }

    @Test @MainActor
    func cooldownStartsWithRestAndFinishesWithCompletion() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer { model.reset() }
        model.loadPreset(preset(sets: 1, cooldown: true))
        model.startPreset()
        probe.seconds = 10
        model.refreshTiming()
        #expect(model.state == .cooldown)
        #expect(probe.cues == [.workBegins, .restBegins])

        probe.seconds = 70
        model.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins])
        probe.seconds = 130
        model.refreshTiming()
        model.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins, .workoutComplete])
        #expect(model.state == .idle)
    }

    @Test @MainActor
    func skippingIntoCooldownPlaysRestCue() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer { model.reset() }
        model.loadPreset(preset(cooldown: true))
        model.startPreset()
        probe.seconds = 3
        model.skipToCooldown()
        #expect(model.state == .cooldown)
        #expect(probe.cues == [.workBegins, .restBegins])
    }

    @Test @MainActor
    func disabledPresetSoundSuppressesAllCues() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel(countdown: 5)
        defer { model.reset() }
        model.loadPreset(preset(cooldown: true, sound: false))
        model.startPreset()
        for boundary in [5.0, 15, 20, 30, 150] {
            probe.seconds = boundary
            model.refreshTiming()
        }
        #expect(model.state == .idle)
        #expect(probe.cues.isEmpty)
    }

    @Test @MainActor
    func recordingSuppressesCuesWithoutReplayingThemAfterRecording() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer {
            WorkoutRecordingAudio.shared.setRecording(false)
            model.reset()
        }
        model.loadPreset(preset())
        WorkoutRecordingAudio.shared.setRecording(true)
        model.startPreset()
        probe.seconds = 10
        model.refreshTiming()
        #expect(probe.cues.isEmpty)

        WorkoutRecordingAudio.shared.setRecording(false)
        model.refreshTiming()
        #expect(probe.cues.isEmpty)
        probe.seconds = 15
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])

        WorkoutRecordingAudio.shared.setRecording(true)
        probe.seconds = 25
        model.refreshTiming()
        WorkoutRecordingAudio.shared.setRecording(false)
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])
        #expect(model.state == .idle)
    }

    @Test(arguments: [0.0, 1.0, 1.01]) @MainActor
    func cuesRequireDeliveryWithinOneSecondOfTheirBoundary(delay: TimeInterval) {
        let probe = TimerSoundProbe()
        let model = probe.makeModel(countdown: 5)
        defer { model.reset() }
        model.loadPreset(preset())
        model.startPreset()
        for boundary in [5.0, 15, 20, 30] {
            probe.seconds = boundary + delay
            model.refreshTiming()
        }

        let expected: [TimerSoundCue] = delay <= 1
            ? [.workBegins, .restBegins, .workBegins, .workoutComplete] : []
        #expect(probe.cues == expected)
        #expect(model.state == .idle)
    }

    @Test(arguments: [0.0, 1.0, 1.01]) @MainActor
    func cooldownCuesUseTheSameTimelinessWindow(delay: TimeInterval) {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer { model.reset() }
        model.loadPreset(preset(sets: 1, cooldown: true))
        model.startPreset()
        probe.cues.removeAll()
        probe.seconds = 10 + delay
        model.refreshTiming()
        probe.seconds = 130 + delay
        model.refreshTiming()
        let expected: [TimerSoundCue] = delay <= 1 ? [.restBegins, .workoutComplete] : []
        #expect(probe.cues == expected)
    }

    @Test @MainActor
    func delayedCallbacksAnnounceOnlyTheCurrentTimelyTransition() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel(countdown: 5)
        defer { model.reset() }
        model.loadPreset(preset())
        model.startPreset()
        probe.seconds = 20.5
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])
        #expect(model.presetCurrentSet == 2)
        #expect(model.presetPhase == .work)

        probe.seconds = 40
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])
        #expect(model.state == .idle)
    }

    @Test @MainActor
    func zeroLengthRestDoesNotPlayTwoCuesAtTheSameBoundary() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer { model.reset() }
        model.loadPreset(preset(rest: 0))
        model.startPreset()
        probe.seconds = 10
        model.refreshTiming()
        #expect(probe.cues == [.workBegins, .workBegins])
        #expect(model.presetCurrentSet == 2)
        #expect(model.presetPhase == .work)
    }

    @Test @MainActor
    func countdownAndWorkPauseResumeDoNotDuplicateCues() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel(countdown: 5)
        defer { model.reset() }
        model.loadPreset(preset())
        model.startPreset()
        probe.seconds = 2
        model.pausePreset()
        probe.seconds = 102
        model.refreshTiming()
        model.startPreset()
        #expect(probe.cues.isEmpty)
        probe.seconds = 105
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])

        probe.seconds = 110
        model.pausePreset()
        probe.seconds = 210
        model.startPreset()
        model.refreshTiming()
        #expect(probe.cues == [.workBegins])
        probe.seconds = 215
        model.refreshTiming()
        model.pausePreset()
        probe.seconds = 315
        model.startPreset()
        #expect(probe.cues == [.workBegins, .restBegins])
        probe.seconds = 320
        model.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins, .workBegins])
    }

    @Test @MainActor
    func cooldownPauseResumeDoesNotRepeatRestCue() {
        let probe = TimerSoundProbe()
        let model = probe.makeModel()
        defer { model.reset() }
        model.loadPreset(preset(sets: 1, cooldown: true))
        model.startPreset()
        probe.seconds = 10
        model.refreshTiming()
        probe.seconds = 20
        model.toggleCooldown()
        probe.seconds = 120
        model.toggleCooldown()
        #expect(probe.cues == [.workBegins, .restBegins])
        probe.seconds = 230
        model.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins, .workoutComplete])
    }

    @Test(arguments: [5.5, 6.1, 20.5, 200.0]) @MainActor
    func restoringCountdownUsesOriginalBoundariesWithoutStaleCues(restoredAt: TimeInterval) {
        let probe = TimerSoundProbe()
        var original: TimerViewModel? = probe.makeModel(countdown: 5)
        original?.loadPreset(preset(cooldown: true))
        original?.startPreset()
        original = nil
        probe.seconds = restoredAt

        let restored = probe.makeModel(countdown: 5)
        defer { restored.reset() }
        let expected: [TimerSoundCue] = restoredAt == 5.5 || restoredAt == 20.5 ? [.workBegins] : []
        #expect(probe.cues == expected)
        restored.refreshTiming()
        #expect(probe.cues == expected)
    }

    @Test @MainActor
    func restoringAlreadyEnteredPhaseDoesNotReplayItsCue() {
        let probe = TimerSoundProbe()
        var original: TimerViewModel? = probe.makeModel()
        original?.loadPreset(preset())
        original?.startPreset()
        probe.seconds = 10
        original?.refreshTiming()
        original = nil
        #expect(probe.cues == [.workBegins, .restBegins])

        let restored = probe.makeModel()
        defer { restored.reset() }
        restored.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins])
        probe.seconds = 15
        restored.refreshTiming()
        #expect(probe.cues == [.workBegins, .restBegins, .workBegins])
    }

    @MainActor
    private func preset(sets: Int = 2, rest: TimeInterval = 5, cooldown: Bool = false, sound: Bool = true) -> TimerPreset {
        TimerPreset(workDuration: 10, restDuration: rest, numberOfSets: sets, includeCooldown: cooldown, playSound: sound)
    }
}

@MainActor
private final class TimerSoundProbe {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let store = ActiveWorkoutSessionStore(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("sound-routing-\(UUID()).json")
    )
    var seconds: TimeInterval = 0
    var cues: [TimerSoundCue] = []

    func makeModel(countdown: TimeInterval = 0) -> TimerViewModel {
        TimerViewModel(
            presetStartCountdownDuration: countdown,
            sessionStore: store,
            nowProvider: { self.origin.addingTimeInterval(self.seconds) },
            soundCueHandler: { self.cues.append($0) }
        )
    }
}
