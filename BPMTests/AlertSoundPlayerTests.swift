import AVFoundation
import Testing
@testable import BPM

private final class StubSoundPlayback: AppSoundPlayback {
    var completion: (() -> Void)?
    var shouldStart = true
    private(set) var stopped = false
    func play() -> Bool { shouldStart }
    func stop() { stopped = true }
    func finish() { completion?() }
}

@MainActor
private final class SoundPlaybackHarness {
    var players: [StubSoundPlayback] = []
    var played: [AppSoundCue] = []
    var activations = 0
    var deactivations = 0
    var recording = false
    var clock: TimeInterval = 0
    var shouldStart = true
    var missingAsset = false

    lazy var player = AlertSoundPlayer(
        makePlayback: { [unowned self] _ in
            if missingAsset { throw CocoaError(.fileNoSuchFile) }
            let playback = StubSoundPlayback()
            playback.shouldStart = shouldStart
            players.append(playback)
            return playback
        },
        activateSession: { [unowned self] in activations += 1 },
        deactivateSession: { [unowned self] in deactivations += 1 },
        isRecording: { [unowned self] in recording },
        now: { [unowned self] in clock },
        didPlay: { [unowned self] in played.append($0) },
        observeAudioSession: false
    )
}

struct AlertSoundPlayerTests {
    @Test func everySoundIsPackagedAndDecodable() throws {
        for cue in AppSoundCue.allCases {
            let url = try #require(cue.resourceURL())
            let file = try AVAudioFile(forReading: url)
            #expect(file.processingFormat.channelCount == 1)
            #expect(file.processingFormat.sampleRate == 44_100)
            #expect(file.length > 0)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            switch cue {
            case .bpmAscending, .bpmDescending: #expect(abs(duration - 0.3) < 0.001)
            case .workBegins: #expect(abs(duration - 2) < 0.001)
            case .restBegins, .workoutComplete: #expect(abs(duration - 1.7) < 0.001)
            case .hrvComplete: #expect(abs(duration - 5.35) < 0.001)
            default: #expect(duration > 0.5 && duration < 1.3)
            }
        }
        #expect(AppSoundCue.zone(0) == nil)
        #expect(AppSoundCue.zone(6) == nil)
    }

    @Test @MainActor func simultaneousBPMAndZonePlayAsWholeCues() {
        let h = SoundPlaybackHarness()
        h.player.playBpmAscending()
        h.player.playZoneCount(3)
        #expect(h.played == [.bpmAscending])
        #expect(!h.players[0].stopped)
        h.players[0].finish()
        #expect(h.played == [.bpmAscending, .zone3])
        #expect(h.deactivations == 0)
        h.players[1].finish()
        #expect(h.deactivations == 1)
    }

    @Test @MainActor func onlyLatestQueuedZoneIsAnnounced() {
        let h = SoundPlaybackHarness()
        h.player.playBpmAscending()
        h.player.playZoneCount(3)
        h.player.playZoneCount(4)
        h.player.playZoneCount(5)
        h.players[0].finish()
        #expect(h.played == [.bpmAscending, .zone5])
        h.players[1].finish()
        #expect(h.players.count == 2)
        #expect(h.deactivations == 1)
    }

    @Test @MainActor func returningToCurrentlyAnnouncedStateCancelsObsoletePendingAlert() {
        let h = SoundPlaybackHarness()
        h.player.playBpmAscending()
        h.player.playBpmDescending()
        h.player.playBpmAscending()
        h.players[0].finish()
        #expect(h.played == [.bpmAscending])
        #expect(h.deactivations == 1)
    }

    @Test @MainActor func phaseCueStartsImmediatelyAndIgnoresStoppedPlayerCompletion() throws {
        let h = SoundPlaybackHarness()
        h.player.playZoneCount(3)
        let obsoleteCompletion = try #require(h.players[0].completion)
        h.player.playBpmDescending()
        h.player.playWorkBegins()
        #expect(h.players[0].stopped)
        #expect(h.played == [.zone3, .workBegins])
        obsoleteCompletion()
        #expect(h.deactivations == 0)
        h.players[1].finish()
        #expect(h.deactivations == 1)
        #expect(h.played == [.zone3, .workBegins])
    }

    @Test @MainActor func alertsDoNotInterruptLongHRVChimeAndStaleAlertsExpire() {
        let h = SoundPlaybackHarness()
        h.player.playHRVComplete()
        h.player.playZoneCount(4)
        h.clock = 5.35
        #expect(!h.players[0].stopped)
        h.players[0].finish()
        #expect(h.played == [.hrvComplete])
        #expect(h.deactivations == 1)
    }

    @Test @MainActor func recordingCancelsQueueAndDoesNotReleaseRecordSession() throws {
        let h = SoundPlaybackHarness()
        h.player.playWorkBegins()
        let obsoleteCompletion = try #require(h.players[0].completion)
        h.player.playZoneCount(3)
        h.recording = true
        h.player.suspendForRecording()
        h.player.playHRVComplete()
        h.player.playRestBegins()
        obsoleteCompletion()
        #expect(h.players[0].stopped)
        #expect(h.played == [.workBegins])
        #expect(h.deactivations == 0)
        h.recording = false
        h.player.playZoneCount(5)
        h.players[1].finish()
        #expect(h.played == [.workBegins, .zone5])
        #expect(h.deactivations == 1)
    }

    @Test @MainActor func failedPlaybackReleasesSessionAndDoesNotCountUsage() {
        let h = SoundPlaybackHarness()
        h.shouldStart = false
        h.player.playWorkBegins()
        #expect(h.activations == 1)
        #expect(h.deactivations == 1)
        #expect(h.played.isEmpty)
    }

    @Test @MainActor func missingAssetDoesNotActivateSession() {
        let h = SoundPlaybackHarness()
        h.missingAsset = true
        h.player.playHRVComplete()
        #expect(h.activations == 0)
        #expect(h.deactivations == 0)
        #expect(h.played.isEmpty)
    }
}
