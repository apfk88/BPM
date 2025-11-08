import Foundation
import Combine

struct ShareResponse: Codable {
    let code: String
    let token: String
}

struct HeartRateResponse: Codable {
    let bpm: Int?
    let max: Int?
    let avg: Int?
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
    
    private let shareExpirationInterval: TimeInterval = 2 * 60 * 60 // 2 hours
    
    private let shareCodeKey = "BPM_ShareCode"
    private let shareTokenKey = "BPM_ShareToken"
    private let friendCodeKey = "BPM_FriendCode"
    
    init() {
        loadSavedState()
    }
    
    private func loadSavedState() {
        // Only restore friend code viewing state, not sharing state
        // Sharing should be explicitly started by the user
        friendCode = UserDefaults.standard.string(forKey: friendCodeKey)
        
        if friendCode != nil {
            isViewing = true
            startPollingFriendHeartRate()
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
    }
    
    func startViewing(code: String) {
        friendCode = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        isViewing = true
        errorMessage = nil
        errorContext = nil
        
        UserDefaults.standard.set(friendCode, forKey: friendCodeKey)
        
        startPollingFriendHeartRate()
    }
    
    func stopViewing(clearError: Bool = true) {
        isViewing = false
        friendCode = nil
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        pollTimer?.invalidate()
        pollTimer = nil
        
        if clearError {
            errorMessage = nil
            errorContext = nil
        }
        
        UserDefaults.standard.removeObject(forKey: friendCodeKey)
    }
    
    func updateHeartRate(_ bpm: Int, max: Int?, avg: Int?) {
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
            self?.pollFriendHeartRate()
        }
        
        // Poll immediately
        pollFriendHeartRate()
    }
    
    private func pollFriendHeartRate() {
        guard let code = friendCode else { return }
        
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
                        self.errorMessage = "Sharing session expired or ended. Ask the sharer to start a new session."
                        self.errorContext = .viewing
                        self.stopViewing(clearError: false)
                    }
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
                    self.friendHeartRate = heartRateResponse.bpm
                    self.friendMaxHeartRate = heartRateResponse.max
                    self.friendAvgHeartRate = heartRateResponse.avg
                    self.errorMessage = nil
                    self.errorContext = nil
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
}

