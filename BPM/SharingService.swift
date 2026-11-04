import Foundation
import Combine
#if canImport(ActivityKit)
import ActivityKit
#endif

struct ShareResponse: Codable {
    let code: String
    let token: String
}

struct HeartRateResponse: Codable {
    let bpm: Int?
    let max: Int?
    let avg: Int?
    let min: Int?
    let timestamp: Int64
    var workout: SharedWorkoutSnapshot? = nil
    var workoutTimestamp: Int64? = nil
    var serverTime: Int64? = nil
    var rrStream: SharedRRStreamSnapshot? = nil
    var rrTimestamp: Int64? = nil
}

private struct RRStreamRequest: Encodable {
    let token: String
    let snapshot: SharedRRStreamSnapshot
}

private struct WorkoutSyncRequest: Encodable {
    let token: String
    let snapshot: SharedWorkoutSnapshot
    let acknowledgedCommandIds: [String]
}

private struct WorkoutSyncResponse: Decodable {
    let commands: [SharedWorkoutCommand]
    let serverTime: Int64
}

private struct WorkoutControlRequest: Encodable {
    let code: String
    let id: String
    let workoutID: String
    let controlRevision: String
    let action: SharedWorkoutAction
    let preset: TimerPreset?
}

private struct PendingWorkoutControl {
    let id: String
    let workoutID: String
    let controlRevision: String
    var expiresAtTicks: TimeInterval?
}

struct ServerErrorResponse: Codable {
    let message: String?
    let error: String?
    let code: String?
}

enum SharingError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case serverError(Int)
}

struct FriendActivityTimer {
    let elapsedSeconds: Int
    let referenceDate: Date?
    let endDate: Date?
    let expiresAt: Date
}

struct FriendHeartRatePoll {
    let sessionID: UUID
    let sequence: UInt64
    let code: String
    let startedAtTicks: TimeInterval
}

class SharingService: ObservableObject {
    static let shared = SharingService()
    
    enum ErrorContext {
        case sharing
        case viewing
    }
    
    @Published var shareCode: String?
    @Published var shareToken: String?
    @Published var friendCode: String?
    @Published var friendHeartRate: Int?
    @Published var friendMaxHeartRate: Int?
    @Published var friendAvgHeartRate: Int?
    @Published var friendMinHeartRate: Int?
    @Published private(set) var friendWorkout: SharedWorkoutSnapshot?
    @Published private(set) var friendWorkoutIsFresh = false
    @Published private(set) var friendRRIntervals: [RRInterval] = []
    @Published private(set) var friendRRStreamID = UUID()
    @Published private(set) var friendSupportsRRIntervals = false
    let friendHeartRateMeasurements = PassthroughSubject<HeartRateSample, Never>()
    private var friendRRBuffer = SharedRRStreamBuffer()
    private var latestRRSupportsIntervals = false
    private var rrUploadSequence: Int64 = 0
    private var rrUnavailableToken: String?
    private var rrUploadRequestID: UUID?
    @Published private(set) var isWorkoutControlPending = false
    @Published private(set) var workoutControlError: String?
    @Published private(set) var workoutSharingError: String?
    @Published var isSharing = false
    @Published var isViewing = false
    @Published var errorMessage: String?
    @Published var errorContext: ErrorContext?
    @Published var viewingStoppedMessage: String?
    @Published var pendingJoinCode: String?
    private var hasConnectedToFriend = false
    private let disconnectLocalMonitor: () -> Void
    private var viewingAnalytics: StreamViewingAnalytics?
    private var broadcastUsage = AnalyticsOncePerSession<String>()
    private let userDefaults: UserDefaults
    private let nowProvider: () -> Date
    private let ticksProvider: () -> TimeInterval
    private let automaticallyPoll: Bool
    private let managesLiveActivities: Bool
    private let networkSession: URLSession
    private var viewingSessionID = UUID()
    private var nextPollSequence: UInt64 = 0
    private var lastProcessedPollSequence: UInt64 = 0
    private var lastServerTimestamp: Int64?
    private var friendReadingExpiresAtTicks: TimeInterval?
    private var friendWorkoutReceivedAtTicks: TimeInterval?
    private var friendWorkoutAgeAtReceipt: TimeInterval = 0
    private var frozenWorkoutPresentationAge: TimeInterval?
    private var lastWorkoutSequence: Int64?
    private var pendingWorkoutControl: PendingWorkoutControl?
    private var hostWorkoutToken: String?
    private var nextWorkoutSequence: Int64 = 0
    private var processedWorkoutCommandIDs = Set<String>()
    private var pendingWorkoutAcknowledgements = Set<String>()
    private var workoutSyncRequestID: UUID?
    private var workoutSyncUnavailableToken: String?
    @Published private var sharingStartRequestID: UUID?
    var isStartingSharing: Bool { sharingStartRequestID != nil }
    private let workoutFreshnessInterval: TimeInterval = 5

    var friendRRAcquisitionTicks: TimeInterval? {
        isViewing && friendRRBuffer.isFresh(at: ticksProvider()) ? friendRRBuffer.sourceTicks : nil
    }

    /// Extrapolate only inside the freshness window; stale displays stop advancing.
    var friendWorkoutPresentationAge: TimeInterval {
        if let frozenWorkoutPresentationAge { return frozenWorkoutPresentationAge }
        guard let received = friendWorkoutReceivedAtTicks else { return 0 }
        return min(workoutFreshnessInterval, max(0, friendWorkoutAgeAtReceipt + ticksProvider() - received))
    }
    
    /// A shared timer is eligible only while its source snapshot is current.
    /// Bound system-rendered time to that same deadline if the app is suspended.
    var friendActivityTimer: FriendActivityTimer? {
        guard isViewing, friendWorkoutIsFresh, let snapshot = friendWorkout,
              let received = friendWorkoutReceivedAtTicks else { return nil }
        switch snapshot.state {
        case .running, .paused, .cooldown, .cooldownPaused:
            break
        case .idle:
            return nil
        }
        let remaining = workoutFreshnessInterval - friendWorkoutAgeAtReceipt - (ticksProvider() - received)
        guard remaining > 0 else { return nil }
        let age = friendWorkoutPresentationAge
        let isCooldown = snapshot.state == .cooldown || snapshot.state == .cooldownPaused
        let elapsed = isCooldown
            ? snapshot.totalTime + max(0, 120 - snapshot.setTime(after: age))
            : snapshot.totalTime(after: age)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return nil }
        let now = nowProvider()
        let expiresAt = now.addingTimeInterval(remaining)
        let advances = isCooldown ? snapshot.setTimeDirection != 0 : snapshot.totalTimeAdvances
        let endDate = isCooldown
            ? min(expiresAt, now.addingTimeInterval(snapshot.setTime(after: age)))
            : expiresAt
        return FriendActivityTimer(
            elapsedSeconds: Int(elapsed),
            referenceDate: advances ? now.addingTimeInterval(-elapsed) : nil,
            endDate: advances ? endDate : nil,
            expiresAt: expiresAt
        )
    }

    private var baseURL: String {
        // Priority: 1. UserDefaults override, 2. Info.plist (set by build script), 3. Production default
        if let userDefaultsURL = userDefaults.string(forKey: "BPM_API_BASE_URL"), !userDefaultsURL.isEmpty {
            return userDefaultsURL
        }
        
        if let infoPlistURL = Bundle.main.infoDictionary?["BPM_API_BASE_URL"] as? String, !infoPlistURL.isEmpty {
            return infoPlistURL
        }
        
        // Default to production URL
        return "https://bpmtracker.app"
    }
    
    private var updateTimer: Timer?
    private var pollTimer: Timer?
    private var expirationTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastFreshDataTicks: TimeInterval?
    private var viewingStartTicks: TimeInterval?
    
    private let shareExpirationInterval: TimeInterval = 90 * 60 // 90 minutes
    private let viewingTimeoutInterval: TimeInterval = 10.0 // 10 seconds
    
    private let shareCodeKey = "BPM_ShareCode"
    private let shareTokenKey = "BPM_ShareToken"
    private let friendCodeKey = "BPM_FriendCode"
    
    init(
        userDefaults: UserDefaults = .standard,
        nowProvider: @escaping () -> Date = Date.init,
        ticksProvider: @escaping () -> TimeInterval = { MeasurementClock.ticks },
        automaticallyPoll: Bool = true,
        managesLiveActivities: Bool = true,
        networkSession: URLSession = .shared,
        disconnectLocalMonitor: (() -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.nowProvider = nowProvider
        self.ticksProvider = ticksProvider
        self.automaticallyPoll = automaticallyPoll
        self.managesLiveActivities = managesLiveActivities
        self.networkSession = networkSession
        self.disconnectLocalMonitor = disconnectLocalMonitor ?? {}
        loadSavedState()
    }
    
    private func loadSavedState() {
        // Only restore friend code viewing state, not sharing state
        // Sharing should be explicitly started by the user
        if let savedCode = userDefaults.string(forKey: friendCodeKey) {
            let sanitized = sanitizeFriendCode(savedCode)
            if sanitized.count == 6 {
                friendCode = sanitized
            } else {
                userDefaults.removeObject(forKey: friendCodeKey)
            }
        }
        
        if friendCode != nil {
            disconnectLocalMonitor()
            viewingAnalytics = StreamViewingAnalytics(restored: true)
            isViewing = true
            viewingStartTicks = ticksProvider()
            startPollingFriendHeartRate()
            startTimeoutTimer()
        }
        
        // Clear any old sharing state that might be lingering
        userDefaults.removeObject(forKey: shareCodeKey)
        userDefaults.removeObject(forKey: shareTokenKey)
        errorMessage = nil
        errorContext = nil
    }
    
    @MainActor
    func startSharing() async throws {
        guard !isViewing else { throw CancellationError() }
        // Home and Workout use the same service, including while the Device
        // sheet is dismissed and reopened during the initial request.
        guard !isSharing, sharingStartRequestID == nil else { return }
        let requestID = UUID()
        sharingStartRequestID = requestID
        AppAnalytics.signal(.streamStartRequested)
        var didStart = false
        defer {
            if !didStart { AppAnalytics.signal(.streamStartFailed) }
            if sharingStartRequestID == requestID { sharingStartRequestID = nil }
        }
        let apiURL = "\(baseURL)/api/share"
        print("🔗 Starting sharing with API URL: \(apiURL)")
        
        guard let url = URL(string: apiURL) else {
            let error = SharingError.invalidURL
            await MainActor.run {
                self.errorMessage = "Invalid API URL. Please check your configuration."
                self.errorContext = .sharing
            }
            throw error
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0 // 10 second timeout
        
        do {
            let (data, response) = try await networkSession.data(for: request)
            guard !Task.isCancelled, sharingStartRequestID == requestID, !isViewing else {
                if let abandoned = try? JSONDecoder().decode(ShareResponse.self, from: data) {
                    await deleteShareSession(token: abandoned.token)
                }
                throw CancellationError()
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let error = SharingError.invalidResponse
                await MainActor.run {
                    self.errorMessage = "Invalid server response. Please try again."
                    self.errorContext = .sharing
                }
                throw error
            }
            
            guard httpResponse.statusCode == 200 else {
                let error = SharingError.serverError(httpResponse.statusCode)
                let serverMessage = Self.extractServerMessage(from: data)
                await MainActor.run {
                    self.errorMessage = serverMessage ?? Self.defaultServerErrorMessage(statusCode: httpResponse.statusCode)
                    self.errorContext = .sharing
                }
                throw error
            }
            
            let shareResponse = try JSONDecoder().decode(ShareResponse.self, from: data)
            
            shareCode = shareResponse.code
            shareToken = shareResponse.token
            isSharing = true
            broadcastUsage = AnalyticsOncePerSession<String>()
            AppAnalytics.signal(.shareOn)
            errorMessage = nil
            errorContext = nil

            userDefaults.set(shareResponse.code, forKey: shareCodeKey)
            userDefaults.set(shareResponse.token, forKey: shareTokenKey)

            startUpdatingHeartRate()
            startExpirationTimer()
            didStart = true
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            guard sharingStartRequestID == requestID, !isViewing else { throw CancellationError() }
            await MainActor.run {
                let errorMessage: String
                switch urlError.code {
                case .notConnectedToInternet:
                    errorMessage = "No internet connection. Please check your network and try again."
                case .networkConnectionLost:
                    errorMessage = "Network connection lost. Please check your connection and try again."
                case .timedOut:
                    errorMessage = "Request timed out. Please check your connection and try again."
                case .cannotFindHost, .cannotConnectToHost:
                    errorMessage = "Cannot connect to server. Please check your internet connection."
                case .cancelled:
                    errorMessage = "Request was cancelled. Please try again."
                default:
                    errorMessage = "Network error: \(urlError.localizedDescription). Please check your connection and try again."
                }
                self.errorMessage = errorMessage
                self.errorContext = .sharing
                print("❌ Sharing error: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
            }
            throw SharingError.networkError(urlError)
        } catch let decodingError as DecodingError {
            await MainActor.run {
                self.errorMessage = "Invalid server response. Please try again."
                self.errorContext = .sharing
                print("❌ Decoding error: \(decodingError)")
            }
            throw SharingError.invalidResponse
        } catch let sharingError as SharingError {
            throw sharingError
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to start sharing: \(error.localizedDescription). Please try again."
                self.errorContext = .sharing
                print("❌ Unexpected error: \(error)")
            }
            throw error
        }
    }
    
    func stopSharing() {
        let wasSharing = isSharing
        let tokenToDelete = shareToken
        sharingStartRequestID = nil
        
        isSharing = false
        shareCode = nil
        shareToken = nil
        updateTimer?.invalidate()
        updateTimer = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        errorMessage = nil
        errorContext = nil
        resetHostWorkoutSync()
        rrUploadSequence = 0
        rrUnavailableToken = nil
        rrUploadRequestID = nil
        
        userDefaults.removeObject(forKey: shareCodeKey)
        userDefaults.removeObject(forKey: shareTokenKey)

        if wasSharing {
            AppAnalytics.signal(.shareOff)
        }
        
        // Keep the sensor and workout activity intact when broadcasting stops.
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *), managesLiveActivities {
            Task { @MainActor in
                guard !self.isSharing else { return }
                HeartRateActivityController.shared.updateSharingState(isSharing: false)
            }
        }
        #endif
        
        // Delete the session from the backend if we have a token
        if let token = tokenToDelete {
            Task {
                await deleteShareSession(token: token)
            }
        }
    }
    
    private func deleteShareSession(token: String) async {
        guard let url = URL(string: "\(baseURL)/api/share") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["token": token]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, response) = try await networkSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("✅ Successfully deleted share session from backend")
                } else {
                    print("⚠️ Failed to delete share session on server: \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Silently handle errors - session is already stopped locally
            print("⚠️ Error deleting share session: \(error.localizedDescription)")
        }
    }
    
    var shareURL: URL? {
        guard let shareCode else { return nil }
        return URL(string: "https://bpmtracker.app/join/\(shareCode)")
    }

    static func friendCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let code: String?
        if url.scheme?.lowercased() == "bpm", url.host == "join" {
            code = components?.queryItems?.first(where: { $0.name == "code" })?.value
        } else if url.scheme == "https", ["bpmtracker.app", "www.bpmtracker.app"].contains(url.host ?? ""),
                  url.pathComponents.count == 3, url.pathComponents[1] == "join" {
            code = url.pathComponents[2]
        } else { return nil }
        guard let code, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return code
    }

    func requestJoinCode(_ code: String) {
        guard canStartViewing(code: code) else { return }
        pendingJoinCode = sanitizeFriendCode(code)
    }

    func canStartViewing(code: String) -> Bool {
        let sanitized = sanitizeFriendCode(code)
        guard sanitized.count == 6 else {
            errorMessage = "Enter a 6-digit code."
            errorContext = .viewing
            return false
        }
        guard sanitized != shareCode else {
            errorMessage = "You can’t join your own session."
            errorContext = .sharing
            return false
        }
        guard !isSharing else {
            errorMessage = "Stop sharing before joining a friend."
            errorContext = .sharing
            return false
        }
        return true
    }

    @discardableResult
    func startViewing(code: String, disconnectMonitor: (() -> Void)? = nil) -> Bool {
        guard canStartViewing(code: code) else { return false }
        let sanitized = sanitizeFriendCode(code)
        if isViewing, friendCode == sanitized { return true }

        sharingStartRequestID = nil
        (disconnectMonitor ?? disconnectLocalMonitor)()
        viewingStoppedMessage = nil
        hasConnectedToFriend = false

        viewingAnalytics?.stop()
        viewingAnalytics = StreamViewingAnalytics(restored: false)
        viewingSessionID = UUID()
        nextPollSequence = 0
        lastProcessedPollSequence = 0
        friendCode = sanitized
        isViewing = true
        errorMessage = nil
        errorContext = nil
        lastFreshDataTicks = nil
        viewingStartTicks = ticksProvider()
        lastServerTimestamp = nil
        friendReadingExpiresAtTicks = nil
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        friendMinHeartRate = nil
        clearFriendWorkout()
        clearFriendRR()

        userDefaults.set(friendCode, forKey: friendCodeKey)
        updateFriendActivity(startingSession: true)

        startPollingFriendHeartRate()
        startTimeoutTimer()
        return true
    }

    func stopViewing(clearError: Bool = true) {
        hasConnectedToFriend = false
        viewingAnalytics?.stop()
        viewingAnalytics = nil
        viewingSessionID = UUID()
        isViewing = false
        friendCode = nil
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        friendMinHeartRate = nil
        clearFriendWorkout()
        clearFriendRR()
        pollTimer?.invalidate()
        pollTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        lastFreshDataTicks = nil
        viewingStartTicks = nil
        lastServerTimestamp = nil
        friendReadingExpiresAtTicks = nil
        
        if clearError {
            errorMessage = nil
            errorContext = nil
        }
        
        userDefaults.removeObject(forKey: friendCodeKey)
        
        // End live activity when viewing stops
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *), managesLiveActivities {
            let sessionID = viewingSessionID
            Task { @MainActor in
                guard !self.isViewing, self.viewingSessionID == sessionID else { return }
                HeartRateActivityController.shared.endViewing()
            }
        }
        #endif
    }
    
    @MainActor
    func syncRRStream(from monitor: HeartRateBluetoothManager) async {
        guard isSharing, let token = shareToken, rrUploadRequestID == nil,
              rrUnavailableToken != token else { return }
        rrUploadSequence += 1
        let snapshot = SharedRRStreamSnapshot.capture(from: monitor, sequence: rrUploadSequence)
        let requestID = UUID()
        rrUploadRequestID = requestID
        defer { if rrUploadRequestID == requestID { rrUploadRequestID = nil } }
        do {
            var request = try workoutRequest(path: "rr", body: RRStreamRequest(token: token, snapshot: snapshot))
            request.timeoutInterval = 3
            let (_, response) = try await networkSession.data(for: request)
            guard isSharing, shareToken == token, rrUploadRequestID == requestID else { return }
            if let response = response as? HTTPURLResponse, [404, 405].contains(response.statusCode) {
                rrUnavailableToken = token
            }
        } catch {
            // A missing packet remains a gap; the next rolling window can recover it.
        }
    }

    /// The host owns all measurements and timer transitions. Remote commands are
    /// requests against a particular revision, never replacement workout state.
    @MainActor
    func syncWorkout(
        snapshotProvider: @MainActor () -> SharedWorkoutSnapshot,
        applyCommand: @MainActor (SharedWorkoutCommand) -> Bool
    ) async {
        guard isSharing, let token = shareToken, workoutSyncRequestID == nil,
              workoutSyncUnavailableToken != token else { return }
        prepareHostWorkoutSync(token: token)
        let requestID = UUID()
        workoutSyncRequestID = requestID
        defer {
            if workoutSyncRequestID == requestID { workoutSyncRequestID = nil }
        }

        // Every applied command gets an immediate new snapshot. The final pass
        // only publishes/acknowledges; additional commands wait for the next tick.
        for pass in 0..<3 {
            guard !Task.isCancelled, isSharing, shareToken == token else { return }
            var snapshot = snapshotProvider()
            nextWorkoutSequence += 1
            snapshot.sequence = nextWorkoutSequence
            let acknowledgements = Set(pendingWorkoutAcknowledgements.sorted().prefix(32))
            let body = WorkoutSyncRequest(
                token: token,
                snapshot: snapshot,
                acknowledgedCommandIds: acknowledgements.sorted()
            )
            do {
                let request = try workoutRequest(path: "workout", body: body)
                let requestStartedAtTicks = ticksProvider()
                let (data, response) = try await networkSession.data(for: request)
                guard !Task.isCancelled, isSharing, shareToken == token, workoutSyncRequestID == requestID else { return }
                guard let response = response as? HTTPURLResponse else { throw SharingError.invalidResponse }
                guard response.statusCode == 200 else {
                    let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data)
                    if response.statusCode == 401 || (response.statusCode == 404 && serverError?.code == "SESSION_NOT_FOUND") {
                        stopSharing()
                        errorMessage = Self.extractServerMessage(from: data)
                            ?? Self.defaultSharingDeniedMessage(statusCode: response.statusCode)
                        errorContext = .sharing
                        return
                    }
                    if response.statusCode == 404 || response.statusCode == 405 {
                        // A server that predates workout sync still supports BPM.
                        // Do not delete a valid broadcast because the new route is absent.
                        workoutSyncUnavailableToken = token
                        workoutSharingError = "Workout sharing is unavailable. Heart rate sharing continues."
                        return
                    }
                    throw SharingError.serverError(response.statusCode)
                }
                let update = try JSONDecoder().decode(WorkoutSyncResponse.self, from: data)
                pendingWorkoutAcknowledgements.subtract(acknowledgements)
                workoutSharingError = nil
                guard pass < 2 else { return }
                let needsAcknowledgement = processWorkoutCommands(
                    update.commands,
                    serverTime: update.serverTime,
                    transportAge: max(0, ticksProvider() - requestStartedAtTicks),
                    token: token,
                    snapshotProvider: snapshotProvider,
                    applyCommand: applyCommand
                )
                if !needsAcknowledgement { return }
            } catch {
                guard isSharing, shareToken == token, workoutSyncRequestID == requestID else { return }
                if !Task.isCancelled {
                    workoutSharingError = "Workout sharing paused. Reconnecting…"
                }
                return
            }
        }
    }

    @MainActor
    @discardableResult
    func processWorkoutCommands(
        _ commands: [SharedWorkoutCommand],
        serverTime: Int64,
        transportAge: TimeInterval = 0,
        token: String,
        snapshotProvider: @MainActor () -> SharedWorkoutSnapshot,
        applyCommand: @MainActor (SharedWorkoutCommand) -> Bool
    ) -> Bool {
        guard isSharing, shareToken == token else { return false }
        prepareHostWorkoutSync(token: token)
        for command in commands {
            pendingWorkoutAcknowledgements.insert(command.id)
            guard processedWorkoutCommandIDs.insert(command.id).inserted else { continue }
            // Count the full round trip conservatively, so a delayed response
            // cannot revive a command that expired in transit.
            let sourceAge = (Double(serverTime) - Double(command.createdAt)) / 1000
            let commandAge = sourceAge + max(0, transportAge)
            let snapshot = snapshotProvider()
            guard sourceAge >= 0, commandAge < workoutFreshnessInterval,
                  snapshot.workoutID == command.workoutID,
                  snapshot.controlRevision == command.controlRevision,
                  snapshot.permits(command.action) else { continue }
            _ = applyCommand(command)
        }
        return !commands.isEmpty
    }

    private func prepareHostWorkoutSync(token: String) {
        guard hostWorkoutToken != token else { return }
        hostWorkoutToken = token
        nextWorkoutSequence = 0
        processedWorkoutCommandIDs.removeAll()
        pendingWorkoutAcknowledgements.removeAll()
        workoutSharingError = nil
        workoutSyncUnavailableToken = nil
    }

    private func resetHostWorkoutSync() {
        hostWorkoutToken = nil
        nextWorkoutSequence = 0
        processedWorkoutCommandIDs.removeAll()
        pendingWorkoutAcknowledgements.removeAll()
        workoutSyncRequestID = nil
        workoutSharingError = nil
        workoutSyncUnavailableToken = nil
    }

    @MainActor
    func requestWorkoutControl(_ action: SharedWorkoutAction, preset: TimerPreset? = nil) async {
        refreshFriendWorkoutFreshness()
        guard isViewing, let code = friendCode, let snapshot = friendWorkout,
              friendWorkoutIsFresh, snapshot.permits(action), !isWorkoutControlPending else { return }
        let sessionID = viewingSessionID
        let commandID = UUID().uuidString
        pendingWorkoutControl = PendingWorkoutControl(
            id: commandID,
            workoutID: snapshot.workoutID,
            controlRevision: snapshot.controlRevision
        )
        isWorkoutControlPending = true
        workoutControlError = nil
        let body = WorkoutControlRequest(
            code: code,
            id: commandID,
            workoutID: snapshot.workoutID,
            controlRevision: snapshot.controlRevision,
            action: action,
            preset: preset
        )
        do {
            let request = try workoutRequest(path: "control", body: body)
            let (data, response) = try await networkSession.data(for: request)
            guard isViewing, viewingSessionID == sessionID, friendCode == code,
                  pendingWorkoutControl?.id == commandID else { return }
            guard let response = response as? HTTPURLResponse else { throw SharingError.invalidResponse }
            guard response.statusCode == 200 else {
                if response.statusCode >= 500 {
                    holdUnconfirmedWorkoutControl()
                    return
                }
                pendingWorkoutControl = nil
                isWorkoutControlPending = false
                workoutControlError = Self.extractServerMessage(from: data)
                    ?? "Could not change the set. Try again."
                if response.statusCode == 404 {
                    let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data)
                    if serverError?.code == "SESSION_NOT_FOUND" {
                        clearFriendWorkout()
                        errorMessage = "Sharing session expired or ended."
                        errorContext = .viewing
                    } else {
                        freezeFriendWorkout()
                        workoutControlError = "Workout controls are unavailable."
                    }
                }
                return
            }
            pendingWorkoutControl?.expiresAtTicks = ticksProvider() + workoutFreshnessInterval
        } catch {
            guard isViewing, viewingSessionID == sessionID, friendCode == code,
                  pendingWorkoutControl?.id == commandID else { return }
            holdUnconfirmedWorkoutControl()
        }
    }

    private func holdUnconfirmedWorkoutControl() {
        // The server may have accepted a request whose response was lost. Keep
        // the same request pending until the host revision changes or its TTL passes.
        pendingWorkoutControl?.expiresAtTicks = ticksProvider() + workoutFreshnessInterval
        workoutControlError = "Waiting for your friend’s workout…"
    }

    private func workoutRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/api/share/\(path)") else { throw SharingError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = workoutFreshnessInterval
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func updateHeartRate(_ bpm: Int?, max: Int?, avg: Int?, min: Int?) {
        guard isSharing, let token = shareToken else { return }

        Task {
            guard let url = URL(string: "\(baseURL)/api/share/beat") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = ["token": token]
            // Send bpm as null when disconnected so viewers see dashes
            if let bpm = bpm {
                body["bpm"] = bpm
            } else {
                body["bpm"] = NSNull()
            }
            if let max = max {
                body["max"] = max
            }
            if let avg = avg {
                body["avg"] = avg
            }
            if let min = min {
                body["min"] = min
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await networkSession.data(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, bpm != nil {
                    await MainActor.run {
                        guard self.isSharing, self.shareToken == token else { return }
                        if self.broadcastUsage.insert("connected") {
                            AppAnalytics.signal(.streamBroadcastConnected)
                        }
                    }
                }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let serverMessage = Self.extractServerMessage(from: data)
                    await MainActor.run {
                        guard self.isSharing, self.shareToken == token else { return }
                        if (400...499).contains(httpResponse.statusCode) {
                            self.stopSharing()
                            self.errorMessage = serverMessage ?? Self.defaultSharingDeniedMessage(statusCode: httpResponse.statusCode)
                            self.errorContext = .sharing
                        } else if let serverMessage {
                            self.errorMessage = serverMessage
                            self.errorContext = .sharing
                        }
                    }
                }
            } catch {
                // Silently handle network errors during updates
            }
        }
    }
    
    private func startUpdatingHeartRate() {
        // Updates will be triggered externally when heart rate changes
        // This just ensures we're ready
    }
    
    private func startExpirationTimer() {
        expirationTimer?.invalidate()
        
        expirationTimer = Timer.scheduledTimer(withTimeInterval: shareExpirationInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopSharing()
                self?.errorMessage = "Sharing session expired after 90 minutes. To keep sharing, start a new session."
                self?.errorContext = .sharing
            }
        }
    }
    
    private func startPollingFriendHeartRate() {
        pollTimer?.invalidate()
        guard automaticallyPoll else { return }
        
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            print("⏰ Polling timer fired")
            self?.pollFriendHeartRate()
        }
        
        // Ensure timer runs on main RunLoop
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        // Poll immediately
        print("🔄 Starting to poll friend heart rate")
        pollFriendHeartRate()
    }
    
    private func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        guard automaticallyPoll else { return }
        timeoutTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshFriendHeartRateFreshness()
        }
        if let timeoutTimer { RunLoop.main.add(timeoutTimer, forMode: .common) }
    }

    func refreshFriendHeartRateFreshness() {
        guard isViewing else { return }
        refreshFriendWorkoutFreshness()
        refreshFriendRRFreshness()
        let nowTicks = ticksProvider()
        let deadline = friendReadingExpiresAtTicks
            ?? (lastFreshDataTicks ?? viewingStartTicks).map { $0 + viewingTimeoutInterval }
        if let deadline, nowTicks >= deadline {
            setViewingError("Shared connection lost. You might need to start a new session.")
        }
    }

    func beginFriendHeartRatePoll() -> FriendHeartRatePoll? {
        guard isViewing, let friendCode else { return nil }
        nextPollSequence += 1
        return FriendHeartRatePoll(sessionID: viewingSessionID, sequence: nextPollSequence,
                                   code: friendCode, startedAtTicks: ticksProvider())
    }

    private func claimPoll(_ poll: FriendHeartRatePoll) -> Bool {
        guard isViewing, viewingSessionID == poll.sessionID, friendCode == poll.code,
              poll.sequence > lastProcessedPollSequence else { return false }
        lastProcessedPollSequence = poll.sequence
        return true
    }

    func receiveFriendHeartRate(_ response: HeartRateResponse, for poll: FriendHeartRatePoll) {
        guard claimPoll(poll) else { return }
        hasConnectedToFriend = true
        if let rrStream = response.rrStream, let timestamp = response.rrTimestamp,
           let serverTime = response.serverTime,
           friendRRBuffer.receive(snapshot: rrStream, serverTimestamp: timestamp, serverTime: serverTime,
                                  receivedAtTicks: ticksProvider(), transportAge: max(0, ticksProvider() - poll.startedAtTicks),
                                  now: nowProvider()) {
            latestRRSupportsIntervals = rrStream.supportsRRIntervals
            friendRRStreamID = friendRRBuffer.streamID ?? friendRRStreamID
            friendRRIntervals = friendRRBuffer.intervals
        }
        refreshFriendRRFreshness()
        // Workout polling must not depend on a monitor sending fresh BPM packets.
        receiveFriendWorkout(response, transportAge: max(0, ticksProvider() - poll.startedAtTicks))
        if let lastServerTimestamp, response.timestamp <= lastServerTimestamp {
            // Polling the same stored packet is not evidence of a new sensor reading.
            refreshFriendHeartRateFreshness()
            return
        }
        let sourceAge = nowProvider().timeIntervalSince1970 - Double(response.timestamp) / 1000
        guard sourceAge.isFinite, sourceAge >= -1, sourceAge < viewingTimeoutInterval,
              response.bpm.map({ $0 > 0 }) ?? true else {
            setViewingError("Shared heart rate data is out of date. Waiting for a fresh reading.")
            return
        }
        lastServerTimestamp = response.timestamp
        guard let bpm = response.bpm else {
            clearFriendMeasurement()
            refreshFriendHeartRateFreshness()
            return
        }
        let nowTicks = ticksProvider()
        let age = Swift.max(0, sourceAge)
        lastFreshDataTicks = nowTicks - age
        friendReadingExpiresAtTicks = nowTicks + viewingTimeoutInterval - age
        friendHeartRate = bpm
        friendHeartRateMeasurements.send(HeartRateSample(value: bpm, timestamp: nowProvider().addingTimeInterval(-age), workoutTime: nil))
        friendMaxHeartRate = response.max
        friendAvgHeartRate = response.avg
        friendMinHeartRate = response.min
        errorMessage = nil
        errorContext = nil
        viewingAnalytics?.receivedData()
        updateFriendActivity()
    }

    func receiveFriendHeartRateError(_ message: String, for poll: FriendHeartRatePoll, sessionEnded: Bool = false) {
        guard claimPoll(poll) else { return }
        if sessionEnded {
            if hasConnectedToFriend {
                stopViewing()
                viewingStoppedMessage = "Your friend stopped sharing."
                return
            }
            clearFriendWorkout()
        } else {
            freezeFriendWorkout()
        }
        setViewingError(message)
    }

    private func receiveFriendWorkout(_ response: HeartRateResponse, transportAge: TimeInterval) {
        defer { updateFriendActivity() }
        guard let snapshot = response.workout else {
            refreshFriendWorkoutFreshness()
            return
        }
        guard snapshot.schemaVersion == 1, snapshot.sequence >= 0,
              let timestamp = response.workoutTimestamp, let serverTime = response.serverTime else {
            freezeFriendWorkout()
            return
        }
        if let lastWorkoutSequence, snapshot.sequence <= lastWorkoutSequence {
            refreshFriendWorkoutFreshness()
            return
        }
        let sourceAge = (Double(serverTime) - Double(timestamp)) / 1000
        guard sourceAge >= 0 else {
            freezeFriendWorkout()
            return
        }
        let age = sourceAge + transportAge
        let revisionChanged = friendWorkout?.workoutID != snapshot.workoutID
            || friendWorkout?.controlRevision != snapshot.controlRevision
        friendWorkout = snapshot
        lastWorkoutSequence = snapshot.sequence
        friendWorkoutReceivedAtTicks = ticksProvider()
        friendWorkoutAgeAtReceipt = min(workoutFreshnessInterval, age)
        friendWorkoutIsFresh = age < workoutFreshnessInterval
        frozenWorkoutPresentationAge = friendWorkoutIsFresh ? nil : workoutFreshnessInterval
        if revisionChanged {
            pendingWorkoutControl = nil
            isWorkoutControlPending = false
            workoutControlError = nil
        }
    }

    func refreshFriendWorkoutFreshness() {
        if friendWorkoutIsFresh, let received = friendWorkoutReceivedAtTicks,
           friendWorkoutAgeAtReceipt + ticksProvider() - received >= workoutFreshnessInterval {
            frozenWorkoutPresentationAge = workoutFreshnessInterval
            friendWorkoutIsFresh = false
            updateFriendActivity()
        }
        if let expiresAtTicks = pendingWorkoutControl?.expiresAtTicks,
           ticksProvider() >= expiresAtTicks {
            pendingWorkoutControl = nil
            isWorkoutControlPending = false
            workoutControlError = "Workout change was not confirmed. Try again."
        }
    }

    private func freezeFriendWorkout() {
        frozenWorkoutPresentationAge = friendWorkoutPresentationAge
        friendWorkoutIsFresh = false
        updateFriendActivity()
    }

    private func clearFriendWorkout() {
        friendWorkout = nil
        friendWorkoutIsFresh = false
        friendWorkoutReceivedAtTicks = nil
        friendWorkoutAgeAtReceipt = 0
        frozenWorkoutPresentationAge = nil
        lastWorkoutSequence = nil
        pendingWorkoutControl = nil
        isWorkoutControlPending = false
        workoutControlError = nil
    }

    private func refreshFriendRRFreshness() {
        friendSupportsRRIntervals = isViewing && latestRRSupportsIntervals && friendRRBuffer.isFresh(at: ticksProvider())
    }

    private func clearFriendRR() {
        friendRRBuffer.reset()
        friendRRIntervals = []
        friendRRStreamID = UUID()
        latestRRSupportsIntervals = false
        friendSupportsRRIntervals = false
    }

    private func setViewingError(_ message: String) {
        errorMessage = message
        errorContext = .viewing
        viewingAnalytics?.failed()
        clearFriendMeasurement()
    }

    private func clearFriendMeasurement() {
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        friendMinHeartRate = nil
        friendReadingExpiresAtTicks = nil
        updateFriendActivity()
    }

    private func updateFriendActivity(startingSession: Bool = false) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *), managesLiveActivities {
            let sessionID = viewingSessionID
            Task { @MainActor [weak self] in
                guard let self, self.isViewing, self.viewingSessionID == sessionID else { return }
                if startingSession {
                    HeartRateActivityController.shared.endViewing()
                }
                let timer = self.friendActivityTimer
                let heartRateExpiresAt = self.friendReadingExpiresAtTicks.map {
                    self.nowProvider().addingTimeInterval(max(0, $0 - self.ticksProvider()))
                }
                HeartRateActivityController.shared.updateActivity(
                    bpm: self.friendHeartRate, average: self.friendAvgHeartRate,
                    maximum: self.friendMaxHeartRate, minimum: self.friendMinHeartRate,
                    zone: nil, isSharing: false, isViewing: true, hasError: self.errorContext == .viewing,
                    elapsedSeconds: timer?.elapsedSeconds,
                    timerReferenceDate: timer?.referenceDate,
                    timerEndDate: timer?.endDate,
                    heartRateExpiresAt: heartRateExpiresAt,
                    timerExpiresAt: timer?.expiresAt
                )
            }
        }
        #endif
    }

    private func pollFriendHeartRate() {
        guard let poll = beginFriendHeartRatePoll() else { return }
        Task {
            guard let url = URL(string: "\(baseURL)/api/share/\(poll.code)") else {
                await MainActor.run {
                    self.receiveFriendHeartRateError("Invalid share code. Please check the code and try again.", for: poll)
                }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = viewingTimeoutInterval
            do {
                let (data, response) = try await networkSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        self.receiveFriendHeartRateError("Connection error. Please check your internet connection.", for: poll)
                    }
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    let message = Self.extractServerMessage(from: data)
                        ?? (httpResponse.statusCode == 404
                            ? "Sharing session expired or ended. Ask the sharer to start a new session."
                            : "Unable to connect to sharing session. Please try again.")
                    await MainActor.run {
                        self.receiveFriendHeartRateError(message, for: poll, sessionEnded: httpResponse.statusCode == 404)
                    }
                    return
                }
                let heartRateResponse = try JSONDecoder().decode(HeartRateResponse.self, from: data)
                await MainActor.run { self.receiveFriendHeartRate(heartRateResponse, for: poll) }
            } catch {
                await MainActor.run {
                    let message: String
                    if let error = error as? URLError,
                       [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
                        message = "Connection lost. Check your internet and try again."
                    } else {
                        message = "Unable to connect. The sharing session may have ended."
                    }
                    self.receiveFriendHeartRateError(message, for: poll)
                }
            }
        }
    }

    private func sanitizeFriendCode(_ code: String) -> String {
        let digits = code.filter { $0.isASCII && $0.isNumber }
        return String(digits.prefix(6))
    }

    private static func extractServerMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
            if let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                return message
            }
            if let legacyError = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyError.isEmpty {
                return legacyError
            }
        }
        return nil
    }

    private static func defaultServerErrorMessage(statusCode: Int) -> String {
        if statusCode == 401 {
            return "Authentication required. Please ensure the sharing API is public."
        }
        if statusCode == 500 {
            return "Server error. Please try again later."
        }
        return "Server error (code \(statusCode)). Please try again."
    }

    private static func defaultSharingDeniedMessage(statusCode: Int) -> String {
        if statusCode == 401 || statusCode == 404 {
            return "Sharing session expired. To keep sharing, start a new session."
        }
        if statusCode == 403 || statusCode == 429 {
            return "Sharing is currently unavailable for this account. Please try again later."
        }
        return "Sharing was denied by the server (code \(statusCode))."
    }
}
