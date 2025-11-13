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
}

enum SharingError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case serverError(Int)
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
    @Published var isSharing = false
    @Published var isViewing = false
    @Published var errorMessage: String?
    @Published var errorContext: ErrorContext?
    
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "BPM_API_BASE_URL") ?? "https://bpm-chi.vercel.app"
    }
    
    private var updateTimer: Timer?
    private var pollTimer: Timer?
    private var expirationTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastHeartRateTimestamp: Date?
    private var viewingStartTime: Date?
    
    private let shareExpirationInterval: TimeInterval = 2 * 60 * 60 // 2 hours
    private let viewingTimeoutInterval: TimeInterval = 10.0 // 10 seconds
    
    private let shareCodeKey = "BPM_ShareCode"
    private let shareTokenKey = "BPM_ShareToken"
    private let friendCodeKey = "BPM_FriendCode"
    
    init() {
        loadSavedState()
    }
    
    private func loadSavedState() {
        // Only restore friend code viewing state, not sharing state
        // Sharing should be explicitly started by the user
        if let savedCode = UserDefaults.standard.string(forKey: friendCodeKey) {
            let sanitized = sanitizeFriendCode(savedCode)
            if sanitized.count == 6 {
                friendCode = sanitized
            } else {
                UserDefaults.standard.removeObject(forKey: friendCodeKey)
            }
        }
        
        if friendCode != nil {
            isViewing = true
            viewingStartTime = Date()
            startPollingFriendHeartRate()
            startTimeoutTimer()
        }
        
        // Clear any old sharing state that might be lingering
        UserDefaults.standard.removeObject(forKey: shareCodeKey)
        UserDefaults.standard.removeObject(forKey: shareTokenKey)
        errorMessage = nil
        errorContext = nil
    }
    
    func startSharing() async throws {
        guard let url = URL(string: "\(baseURL)/api/share") else {
            throw SharingError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SharingError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw SharingError.serverError(httpResponse.statusCode)
            }
            
            let shareResponse = try JSONDecoder().decode(ShareResponse.self, from: data)
            
            await MainActor.run {
                self.shareCode = shareResponse.code
                self.shareToken = shareResponse.token
                self.isSharing = true
                self.errorMessage = nil
                self.errorContext = nil
                
                UserDefaults.standard.set(shareResponse.code, forKey: self.shareCodeKey)
                UserDefaults.standard.set(shareResponse.token, forKey: self.shareTokenKey)
                
                self.startUpdatingHeartRate()
                self.startExpirationTimer()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to start sharing: \(error.localizedDescription)"
                self.errorContext = .sharing
            }
            throw error
        }
    }
    
    func stopSharing() {
        let tokenToDelete = shareToken
        
        isSharing = false
        shareCode = nil
        shareToken = nil
        updateTimer?.invalidate()
        updateTimer = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        errorMessage = nil
        errorContext = nil
        
        UserDefaults.standard.removeObject(forKey: shareCodeKey)
        UserDefaults.standard.removeObject(forKey: shareTokenKey)
        
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
            let (_, response) = try await URLSession.shared.data(for: request)
            
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
    
    func startViewing(code: String) {
        let sanitized = sanitizeFriendCode(code)
        guard sanitized.count == 6 else {
            return
        }

        friendCode = sanitized
        isViewing = true
        errorMessage = nil
        errorContext = nil
        lastHeartRateTimestamp = nil
        viewingStartTime = Date()
        friendMinHeartRate = nil

        UserDefaults.standard.set(friendCode, forKey: friendCodeKey)

        startPollingFriendHeartRate()
        startTimeoutTimer()
    }

    func stopViewing(clearError: Bool = true) {
        isViewing = false
        friendCode = nil
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        friendMinHeartRate = nil
        pollTimer?.invalidate()
        pollTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        lastHeartRateTimestamp = nil
        viewingStartTime = nil
        
        if clearError {
            errorMessage = nil
            errorContext = nil
        }
        
        UserDefaults.standard.removeObject(forKey: friendCodeKey)
    }
    
    func updateHeartRate(_ bpm: Int, max: Int?, avg: Int?, min: Int?) {
        guard isSharing, let token = shareToken else { return }

        Task {
            guard let url = URL(string: "\(baseURL)/api/share/beat") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = ["token": token, "bpm": bpm]
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
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    await MainActor.run {
                        if httpResponse.statusCode == 401 {
                            self.stopSharing()
                            self.errorMessage = "Sharing session expired. To keep sharing, start a new session."
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
                self?.errorMessage = "Sharing session expired after 2 hours. To keep sharing, start a new session."
                self?.errorContext = .sharing
            }
        }
    }
    
    private func startPollingFriendHeartRate() {
        pollTimer?.invalidate()
        
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
        
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                guard self.isViewing else { return }
                
                let now = Date()
                
                if let lastUpdate = self.lastHeartRateTimestamp {
                    // We've received at least one update - check if it's been too long since the last one
                    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                    if timeSinceLastUpdate >= self.viewingTimeoutInterval {
                        // Only show timeout error if we don't already have an error message
                        if self.errorMessage == nil {
                            self.errorMessage = "Shared connection lost. You might need to start a new session."
                            self.errorContext = .viewing
                        }
                    }
                } else if let startTime = self.viewingStartTime {
                    // We've never received an update - check if enough time has passed since we started viewing
                    let timeSinceStart = now.timeIntervalSince(startTime)
                    if timeSinceStart >= self.viewingTimeoutInterval {
                        if self.errorMessage == nil {
                            self.errorMessage = "Shared connection lost. You might need to start a new session."
                            self.errorContext = .viewing
                        }
                    }
                }
            }
        }
        
        // Ensure timer runs on main RunLoop
        if let timer = timeoutTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func pollFriendHeartRate() {
        guard let code = friendCode else {
            print("⚠️ No friend code, skipping poll")
            return
        }
        
        print("📡 Polling friend heart rate for code: \(code)")
        Task {
            guard let url = URL(string: "\(baseURL)/api/share/\(code)") else {
                await MainActor.run {
                    self.errorMessage = "Invalid share code. Please check the code and try again."
                    self.errorContext = .viewing
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        self.errorMessage = "Connection error. Please check your internet connection."
                        self.errorContext = .viewing
                    }
                    return
                }
                
                if httpResponse.statusCode == 404 {
                    await MainActor.run {
                        print("⚠️ Viewer received 404 - sharing session expired")
                        self.errorMessage = "Sharing session expired or ended. Ask the sharer to start a new session."
                        self.errorContext = .viewing
                        
                        // Update activity with error state - keep last known BPM if available
                        #if canImport(ActivityKit)
                        if #available(iOS 16.1, *) {
                            // Use last known BPM if available, otherwise use 0 as placeholder
                            let lastBPM = self.friendHeartRate ?? 0
                            print("📱 Updating activity with error state, BPM: \(lastBPM)")
                            HeartRateActivityController.shared.updateActivity(
                                bpm: lastBPM,
                                average: self.friendAvgHeartRate,
                                maximum: self.friendMaxHeartRate,
                                minimum: self.friendMinHeartRate,
                                isSharing: false,
                                isViewing: true,
                                hasError: true
                            )
                        }
                        #endif
                    }
                    // Continue polling - timer will call this again in 1 second to keep error state visible
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        self.errorMessage = "Unable to connect to sharing session. Please try again."
                        self.errorContext = .viewing
                    }
                    return
                }
                
                let heartRateResponse = try JSONDecoder().decode(HeartRateResponse.self, from: data)
                
                await MainActor.run {
                    print("✅ Received heart rate response: BPM=\(heartRateResponse.bpm?.description ?? "nil"), Max=\(heartRateResponse.max?.description ?? "nil"), Avg=\(heartRateResponse.avg?.description ?? "nil")")
                    
                    // Only update timestamp if we actually received heart rate data
                    // This ensures timeout works correctly - if we get responses but no data, timeout should still trigger
                    if heartRateResponse.bpm != nil {
                        self.lastHeartRateTimestamp = Date()
                    }
                    self.friendHeartRate = heartRateResponse.bpm
                    self.friendMaxHeartRate = heartRateResponse.max
                    self.friendAvgHeartRate = heartRateResponse.avg
                    self.friendMinHeartRate = heartRateResponse.min
                    // Clear error message only if we got actual data
                    if heartRateResponse.bpm != nil {
                        self.errorMessage = nil
                        self.errorContext = nil
                        print("✅ Cleared error message")
                    }
                    
                    // Update activity when viewing friend's heart rate
                    #if canImport(ActivityKit)
                    if #available(iOS 16.1, *) {
                        // Always update activity, even if bpm is nil (to clear error state)
                        let bpm = heartRateResponse.bpm ?? (self.friendHeartRate ?? 0)
                        HeartRateActivityController.shared.updateActivity(
                            bpm: bpm,
                            average: heartRateResponse.avg,
                            maximum: heartRateResponse.max,
                            minimum: heartRateResponse.min,
                            isSharing: false,
                            isViewing: true,
                            hasError: false
                        )
                    }
                    #endif
                }
            } catch {
                await MainActor.run {
                    if let urlError = error as? URLError {
                        switch urlError.code {
                        case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                            self.errorMessage = "Connection lost. Check your internet and try again."
                            self.errorContext = .viewing
                        default:
                            self.errorMessage = "Unable to connect. The sharing session may have ended."
                            self.errorContext = .viewing
                        }
                    } else {
                        self.errorMessage = "Unable to connect. The sharing session may have ended."
                        self.errorContext = .viewing
                    }
                }
            }
        }
    }

    private func sanitizeFriendCode(_ code: String) -> String {
        let digits = code.filter { $0.isNumber }
        return String(digits.prefix(6))
    }
}

