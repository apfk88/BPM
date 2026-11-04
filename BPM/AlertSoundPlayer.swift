//
//  AlertSoundPlayer.swift
//  BPM
//

import AVFoundation
import OSLog

/// Semantic events stay separate even when two events share an audio asset.
enum AppSoundCue: String, CaseIterable {
    case bpmAscending, bpmDescending
    case zone1, zone2, zone3, zone4, zone5
    case workBegins, restBegins, workoutComplete, hrvComplete

    var assetName: String {
        switch self {
        case .bpmAscending: return "bpm-threshold-up"
        case .bpmDescending: return "bpm-threshold-down"
        case .zone1: return "zone-1"
        case .zone2: return "zone-2"
        case .zone3: return "zone-3"
        case .zone4: return "zone-4"
        case .zone5: return "zone-5"
        case .workBegins: return "work-begins"
        case .restBegins, .workoutComplete: return "rest-begins"
        case .hrvComplete: return "hrv-complete"
        }
    }

    var analyticsCategory: AppAnalytics.Sound {
        switch self {
        case .bpmAscending, .bpmDescending: return .bpmAlert
        case .zone1, .zone2, .zone3, .zone4, .zone5: return .zoneAlert
        case .workBegins, .restBegins, .workoutComplete: return .presetBell
        case .hrvComplete: return .hrvCompletion
        }
    }

    var interruptsAlerts: Bool {
        switch self {
        case .workBegins, .restBegins, .workoutComplete, .hrvComplete: return true
        default: return false
        }
    }

    static func zone(_ number: Int) -> AppSoundCue? {
        switch number {
        case 1: return .zone1
        case 2: return .zone2
        case 3: return .zone3
        case 4: return .zone4
        case 5: return .zone5
        default: return nil
        }
    }

    func resourceURL(in bundle: Bundle = .main) -> URL? {
        // Synchronized Xcode groups can copy resources flat or preserve their folder.
        bundle.url(forResource: assetName, withExtension: "wav", subdirectory: "Sounds")
            ?? bundle.url(forResource: assetName, withExtension: "wav")
    }
}

protocol AppSoundPlayback: AnyObject {
    var completion: (() -> Void)? { get set }
    func play() -> Bool
    func stop()
}

private final class BundledSoundPlayback: NSObject, AppSoundPlayback, AVAudioPlayerDelegate {
    var completion: (() -> Void)?
    private let player: AVAudioPlayer

    init(cue: AppSoundCue) throws {
        guard let url = cue.resourceURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func play() -> Bool {
        player.prepareToPlay()
        return player.play()
    }
    func stop() { player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completion?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        completion?()
    }
}

/// Playback and audio-session ownership are confined to the main thread.
final class AlertSoundPlayer {
    static let shared = AlertSoundPlayer()
    private static let logger = Logger(subsystem: "kvamme.BPM", category: "Sounds")
    private static let maximumAlertAge: TimeInterval = 3

    private struct PendingCue {
        let cue: AppSoundCue
        let requestedAt: TimeInterval
    }

    private let makePlayback: (AppSoundCue) throws -> AppSoundPlayback
    private let activateSession: () throws -> Void
    private let deactivateSession: () throws -> Void
    private let isRecording: () -> Bool
    private let now: () -> TimeInterval
    private let didPlay: (AppSoundCue) -> Void
    private var playback: AppSoundPlayback?
    private var currentCue: AppSoundCue?
    private var playbackToken: UUID?
    private var pending: [PendingCue] = []
    private var ownsPlaybackSession = false
    private var observers: [NSObjectProtocol] = []

    init(
        makePlayback: @escaping (AppSoundCue) throws -> AppSoundPlayback = { try BundledSoundPlayback(cue: $0) },
        activateSession: @escaping () throws -> Void = {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        },
        deactivateSession: @escaping () throws -> Void = {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        },
        isRecording: @escaping () -> Bool = { WorkoutRecordingAudio.shared.isRecording },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        didPlay: @escaping (AppSoundCue) -> Void = { AppAnalytics.soundUsed($0.analyticsCategory) },
        observeAudioSession: Bool = true
    ) {
        self.makePlayback = makePlayback
        self.activateSession = activateSession
        self.deactivateSession = deactivateSession
        self.isRecording = isRecording
        self.now = now
        self.didPlay = didPlay
        if observeAudioSession { observeInterruptions() }
    }

    func playBpmAscending() { play(.bpmAscending) }
    func playBpmDescending() { play(.bpmDescending) }
    func playWorkBegins() { play(.workBegins) }
    func playRestBegins() { play(.restBegins) }
    func playWorkoutComplete() { play(.workoutComplete) }
    func playHRVComplete() { play(.hrvComplete) }

    func playZoneCount(_ count: Int) {
        guard let cue = AppSoundCue.zone(count) else { return }
        play(cue)
    }

    func play(_ cue: AppSoundCue) {
        onMain { [weak self] in self?.enqueue(cue) }
    }

    /// Synchronous handoff: no queued completion may deactivate the recording session.
    func suspendForRecording() {
        let suspend = { [self] in
            stopCurrent()
            pending.removeAll()
            ownsPlaybackSession = false
        }
        if Thread.isMainThread { suspend() } else { DispatchQueue.main.sync(execute: suspend) }
    }

    private func enqueue(_ cue: AppSoundCue) {
        guard !isRecording() else { return }
        if cue.interruptsAlerts {
            // Timed phase boundaries must not wait behind a spoken zone or old alert.
            stopCurrent()
            pending.removeAll()
            if !start(cue) { releaseSession() }
            return
        }
        pending.removeAll { $0.cue.analyticsCategory == cue.analyticsCategory }
        guard currentCue != cue else { return }
        if playback == nil {
            if !start(cue) { releaseSession() }
        } else {
            // Keep one whole cue per alert category, replacing obsolete queued readings.
            pending.append(PendingCue(cue: cue, requestedAt: now()))
        }
    }

    private func start(_ cue: AppSoundCue) -> Bool {
        guard !isRecording() else { return false }
        do {
            let next = try makePlayback(cue)
            try activateSession()
            ownsPlaybackSession = true
            let token = UUID()
            playbackToken = token
            playback = next
            currentCue = cue
            next.completion = { [weak self] in
                self?.onMain { [weak self] in self?.finished(token: token) }
            }
            guard next.play() else {
                stopCurrent()
                return false
            }
            didPlay(cue)
            return true
        } catch {
            Self.logger.error("Could not play \(cue.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func finished(token: UUID) {
        guard playbackToken == token else { return }
        playback = nil
        playbackToken = nil
        currentCue = nil
        guard !isRecording() else {
            pending.removeAll()
            ownsPlaybackSession = false
            return
        }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            guard now() - next.requestedAt <= Self.maximumAlertAge else { continue }
            if start(next.cue) { return }
        }
        releaseSession()
    }

    private func stopCurrent() {
        playbackToken = nil
        playback?.completion = nil
        playback?.stop()
        playback = nil
        currentCue = nil
    }

    private func releaseSession() {
        guard ownsPlaybackSession else { return }
        ownsPlaybackSession = false
        guard !isRecording() else { return }
        do { try deactivateSession() }
        catch { Self.logger.error("Could not release sound session: \(error.localizedDescription, privacy: .public)") }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.cancelPlayback()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.cancelPlayback()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelPlayback()
        })
    }

    private func cancelPlayback() {
        stopCurrent()
        pending.removeAll()
        releaseSession()
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
