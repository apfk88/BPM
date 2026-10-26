import Foundation

enum WorkoutVoiceConsent {
    static let defaultsKey = "workoutVoiceOpenAIConsentV1"
}

struct WorkoutRecap: Codable, Equatable {
    var title: String
    var description: String
}

enum WorkoutRecapError: LocalizedError {
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The workout response was incomplete. Try sending again."
        case .service(let message): return message
        }
    }
}

struct WorkoutRecapClient {
    var session: URLSession = .shared
    var baseURL: URL = {
        let configured = UserDefaults.standard.string(forKey: "BPM_API_BASE_URL")
            ?? Bundle.main.infoDictionary?["BPM_API_BASE_URL"] as? String
            ?? "https://bpmtracker.app"
        return URL(string: configured) ?? URL(string: "https://bpmtracker.app")!
    }()

    func generate(audioURL: URL) async throws -> WorkoutRecap {
        let audio = try Data(contentsOf: audioURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/workout-recap"))
        request.httpMethod = "POST"
        request.timeoutInterval = 65
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["audio": audio.base64EncodedString()])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw WorkoutRecapError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorBody: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw WorkoutRecapError.service(message ?? "Voice capture is unavailable right now. Try again shortly.")
        }
        let result = try JSONDecoder().decode(WorkoutRecap.self, from: data)
        guard !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.title.count <= 80,
              !result.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.description.count <= 6000 else { throw WorkoutRecapError.invalidResponse }
        return result
    }
}
