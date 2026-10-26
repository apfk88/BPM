import AVFoundation
import Combine
import UIKit

/// Shared audio ownership: queued alerts must not reconfigure the recording session.
final class WorkoutRecordingAudio {
    static let shared = WorkoutRecordingAudio()
    private let lock = NSLock()
    private var recording = false
    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }
    func setRecording(_ value: Bool) {
        lock.lock(); recording = value; lock.unlock()
    }
}

protocol WorkoutAudioRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}
extension AVAudioRecorder: WorkoutAudioRecording {}

@MainActor
final class WorkoutDictation: ObservableObject {
    static let maximumDuration: TimeInterval = 60
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var audioURL: URL?
    @Published private(set) var message: String?
    private var recorder: WorkoutAudioRecording?
    private var recordingURL: URL?
    private var ticker: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private let microphonePermission: () async -> Bool
    private let makeRecorder: (URL) throws -> WorkoutAudioRecording
    private let activateAudio: () throws -> Void
    private let deactivateAudio: () -> Void

    init(
        microphonePermission: @escaping () async -> Bool = {
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        },
        makeRecorder: @escaping (URL) throws -> WorkoutAudioRecording = { url in
            try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
        },
        activateAudio: @escaping () throws -> Void = {
            AlertSoundPlayer.shared.suspendForRecording()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        },
        deactivateAudio: @escaping () -> Void = {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    ) {
        self.microphonePermission = microphonePermission
        self.makeRecorder = makeRecorder
        self.activateAudio = activateAudio
        self.deactivateAudio = deactivateAudio
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording || self.isRequestingPermission else { return }
                    self.finishRecording()
                    self.message = "Recording stopped after an interruption. Send what you recorded or try again."
                }
            })
        }
    }

    deinit {
        ticker?.cancel()
        recorder?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    }

    func start(prepareAudio: () -> Void) async {
        guard !isRecording, !isRequestingPermission, !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        isRequestingPermission = true
        message = nil
        defer { if generation == token { isRequestingPermission = false } }
        let allowed = await microphonePermission()
        guard generation == token, !Task.isCancelled else { return }
        guard allowed else {
            message = "Microphone access is off. Enable it in Settings, or type your workout."
            return
        }
        discardRecording()
        do {
            prepareAudio()
            WorkoutRecordingAudio.shared.setRecording(true)
            try activateAudio()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workout-\(UUID().uuidString).wav")
            recordingURL = url
            let recorder = try makeRecorder(url)
            self.recorder = recorder
            guard recorder.record(forDuration: Self.maximumDuration) else {
                throw CocoaError(.fileWriteUnknown)
            }
            isRecording = true
            // The recorder enforces the duration even if the UI task is delayed.
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                    self.duration = min(Self.maximumDuration, max(self.duration, recorder.currentTime))
                    if !recorder.isRecording || self.duration >= Self.maximumDuration {
                        self.finishRecording()
                        return
                    }
                }
            }
        } catch {
            discardRecording()
            message = "Recording could not start. Try again or type your workout."
        }
    }

    func finishRecording() {
        generation = UUID()
        isRequestingPermission = false
        ticker?.cancel()
        ticker = nil
        if let recorder {
            duration = min(Self.maximumDuration, max(duration, recorder.currentTime))
            recorder.stop()
        }
        recorder = nil
        if let recordingURL, let file = try? AVAudioFile(forReading: recordingURL), file.processingFormat.sampleRate > 0 {
            duration = min(Self.maximumDuration, Double(file.length) / file.processingFormat.sampleRate)
        }
        if isRecording || WorkoutRecordingAudio.shared.isRecording {
            deactivateAudio()
            WorkoutRecordingAudio.shared.setRecording(false)
        }
        isRecording = false
        audioURL = duration >= 0.5 ? recordingURL : nil
        if audioURL == nil, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            message = "Record at least a moment of speech, then send."
        }
    }

    func discardRecording() {
        finishRecording()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        audioURL = nil
        duration = 0
        message = nil
    }
}
