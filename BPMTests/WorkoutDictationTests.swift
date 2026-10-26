import Testing
import AVFoundation
@testable import BPM

@MainActor
private final class StubWorkoutRecorder: WorkoutAudioRecording {
    var currentTime: TimeInterval = 0
    var isRecording = false
    var limit: TimeInterval?
    func record(forDuration duration: TimeInterval) -> Bool { limit = duration; isRecording = true; return true }
    func stop() { isRecording = false }
}

@Suite(.serialized)
struct WorkoutDictationTests {
    @Test @MainActor func deniedMicrophoneDoesNotAcquireAudio() async {
        let recorder = WorkoutDictation(microphonePermission: { false })
        await recorder.start { Issue.record("Must not acquire audio after microphone denial") }
        #expect(!recorder.isRecording)
        #expect(!recorder.isRequestingPermission)
        #expect(recorder.audioURL == nil)
        #expect(recorder.message?.contains("Microphone access is off") == true)
    }

    @Test @MainActor func cancelPendingPermissionCannotStartRecordingLater() async {
        var continuation: CheckedContinuation<Bool, Never>?
        let recorder = WorkoutDictation(microphonePermission: {
            await withCheckedContinuation { continuation = $0 }
        })
        let task = Task { await recorder.start { Issue.record("Cancelled recording must not take audio") } }
        while continuation == nil { await Task.yield() }
        recorder.discardRecording()
        continuation?.resume(returning: true)
        await task.value
        #expect(!recorder.isRecording)
        #expect(!recorder.isRequestingPermission)
    }

    @Test @MainActor func interruptionCancelsPendingPermission() async {
        var continuation: CheckedContinuation<Bool, Never>?
        let recorder = WorkoutDictation(microphonePermission: {
            await withCheckedContinuation { continuation = $0 }
        })
        let task = Task { await recorder.start { Issue.record("Interrupted recording must not take audio") } }
        while continuation == nil { await Task.yield() }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
        while recorder.isRequestingPermission { await Task.yield() }
        continuation?.resume(returning: true)
        await task.value
        #expect(!recorder.isRecording)
        #expect(recorder.message?.contains("interruption") == true)
    }

    @Test @MainActor func recordingHasHardLimitAndRetainsFileUntilDiscarded() async throws {
        let audio = StubWorkoutRecorder()
        var released = false
        let recorder = WorkoutDictation(microphonePermission: { true }, makeRecorder: { url in
            try Data("synthetic audio".utf8).write(to: url)
            return audio
        }, activateAudio: {}, deactivateAudio: { released = true })
        await recorder.start {}
        #expect(audio.limit == 60)
        #expect(WorkoutRecordingAudio.shared.isRecording)
        audio.currentTime = 4
        recorder.finishRecording()
        let url = try #require(recorder.audioURL)
        #expect(recorder.duration == 4)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(released)
        #expect(!WorkoutRecordingAudio.shared.isRecording)
        recorder.discardRecording()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(recorder.audioURL == nil)
    }

    @Test @MainActor func recordingAutomaticallyStopsAtSixtySeconds() async {
        let audio = StubWorkoutRecorder()
        let recorder = WorkoutDictation(microphonePermission: { true }, makeRecorder: { _ in audio }, activateAudio: {}, deactivateAudio: {})
        await recorder.start {}
        audio.currentTime = 60
        try? await Task.sleep(for: .milliseconds(250))
        #expect(!recorder.isRecording)
        #expect(!audio.isRecording)
        #expect(recorder.duration == 60)
        #expect(recorder.audioURL != nil)
        recorder.discardRecording()
    }

    @Test @MainActor func interruptionRetainsRecordedAudioAndReleasesSession() async {
        let audio = StubWorkoutRecorder()
        let recorder = WorkoutDictation(microphonePermission: { true }, makeRecorder: { _ in audio }, activateAudio: {}, deactivateAudio: {})
        await recorder.start {}
        audio.currentTime = 3
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
        while recorder.isRecording { await Task.yield() }
        #expect(recorder.audioURL != nil)
        #expect(recorder.duration == 3)
        #expect(!WorkoutRecordingAudio.shared.isRecording)
        recorder.discardRecording()
    }
}
