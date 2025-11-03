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
    
    @Published var shareCode: String?
    @Published var shareToken: String?
    @Published var friendCode: String?
    @Published var friendHeartRate: Int?
    @Published var friendMaxHeartRate: Int?
    @Published var friendAvgHeartRate: Int?
    @Published var isSharing = false
    @Published var isViewing = false
    @Published var errorMessage: String?
    
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "BPM_API_BASE_URL") ?? "https://bpm-chi.vercel.app"
    }
    
    private var updateTimer: Timer?
    private var pollTimer: Timer?
    
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
                
                UserDefaults.standard.set(shareResponse.code, forKey: self.shareCodeKey)
                UserDefaults.standard.set(shareResponse.token, forKey: self.shareTokenKey)
                
                self.startUpdatingHeartRate()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to start sharing: \(error.localizedDescription)"
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
        
        UserDefaults.standard.removeObject(forKey: shareCodeKey)
        UserDefaults.standard.removeObject(forKey: shareTokenKey)
    }
    
    func startViewing(code: String) {
        friendCode = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        isViewing = true
        errorMessage = nil
        
        UserDefaults.standard.set(friendCode, forKey: friendCodeKey)
        
        startPollingFriendHeartRate()
    }
    
    func stopViewing() {
        isViewing = false
        friendCode = nil
        friendHeartRate = nil
        friendMaxHeartRate = nil
        friendAvgHeartRate = nil
        pollTimer?.invalidate()
        pollTimer = nil
        
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
                            self.errorMessage = "Sharing session expired"
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
                    self.errorMessage = "Invalid URL"
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        self.errorMessage = "Invalid response"
                    }
                    return
                }
                
                if httpResponse.statusCode == 404 {
                    await MainActor.run {
                        self.errorMessage = "Share code not found"
                        self.stopViewing()
                    }
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        self.errorMessage = "Server error"
                    }
                    return
                }
                
                let heartRateResponse = try JSONDecoder().decode(HeartRateResponse.self, from: data)
                
                await MainActor.run {
                    self.friendHeartRate = heartRateResponse.bpm
                    self.friendMaxHeartRate = heartRateResponse.max
                    self.friendAvgHeartRate = heartRateResponse.avg
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to fetch: \(error.localizedDescription)"
                }
            }
        }
    }
}

