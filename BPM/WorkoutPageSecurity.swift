import Foundation
import CryptoKit
import Security
import DeviceCheck

protocol WorkoutPageSecureStoring {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
}

struct WorkoutPageKeychain: WorkoutPageSecureStoring {
    private let service = "app.bpmtracker.workout-pages.v1"

    func data(for key: String) throws -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw WorkoutPageError.secureStorage }
        return data
    }

    func set(_ data: Data, for key: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            for (key, value) in update { insert[key] = value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw WorkoutPageError.secureStorage }
        } else if status != errSecSuccess { throw WorkoutPageError.secureStorage }
    }
}

enum WorkoutPageCrypto {
    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkoutPageError.secureStorage
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        guard !string.isEmpty, string.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
        }) else { return nil }
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }

    /// Grants access only to the link-preview image. The full workout still
    /// requires the separate view key in the URL fragment.
    static func previewToken(viewKey: String, pageID: String) throws -> String {
        guard decodeBase64URL(viewKey)?.count == 32 else { throw WorkoutPageError.invalidResponse }
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(viewKey.utf8))))
        let message = Data("BPM-Workout-Preview|\(pageID)".utf8)
        return base64URL(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    /// A shorter image-only capability. It never replaces the full workout's view key.
    static func linkCode(viewKey: String, pageID: String) throws -> String {
        guard decodeBase64URL(viewKey)?.count == 32 else { throw WorkoutPageError.invalidResponse }
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(viewKey.utf8))))
        let message = Data("BPM-Workout-Link|\(pageID)".utf8)
        return base64URL(Data(HMAC<SHA256>.authenticationCode(for: message, using: key).prefix(16)))
    }

    static func derive(root: String, purpose: String) throws -> Data {
        guard let data = decodeBase64URL(root), data.count == 32 else { throw WorkoutPageError.invalidRecoveryCode }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: data),
                                       salt: Data("BPM-Workout-Pages-v1".utf8),
                                       info: Data(purpose.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func ownerKey(root: String) throws -> String { base64URL(try derive(root: root, purpose: "management-authority")) }

    static func ownerID(root: String) throws -> String { digest(try ownerKey(root: root)) }

    static func seal(_ data: Data, root: String, context: String) throws -> String {
        let key = SymmetricKey(data: try derive(root: root, purpose: "registry-encryption"))
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw WorkoutPageError.secureStorage }
        return base64URL(combined)
    }

    static func open(_ envelope: String, root: String, context: String) throws -> Data {
        guard let data = decodeBase64URL(envelope) else { throw WorkoutPageError.invalidRecoveryCode }
        let key = SymmetricKey(data: try derive(root: root, purpose: "registry-encryption"))
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }
}

typealias WorkoutPageTransport = (URLRequest) async throws -> (Data, HTTPURLResponse)

enum WorkoutPageHTTP {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    static func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WorkoutPageError.invalidResponse }
        return (data, response)
    }

    static func checked(_ request: URLRequest, transport: WorkoutPageTransport) async throws -> Data {
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 413 { throw WorkoutPageError.tooLarge }
            struct ErrorBody: Decodable { let message: String; let code: String }
            if let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                // Codes are useful to the client; never expose diagnostic response dumps or credentials.
                throw WorkoutPageError.server(String(error.message.prefix(400)), code: error.code)
            }
            if response.statusCode == 404 { throw WorkoutPageError.missingPage }
            throw WorkoutPageError.unavailable
        }
        guard data.count <= WorkoutPageExport.maximumDecodedBytes else { throw WorkoutPageError.tooLarge }
        return data
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

@MainActor
protocol WorkoutPageAttesting {
    func authorize(_ request: URLRequest, ownerKey: String) async throws -> URLRequest
    func invalidate(ownerKey: String) throws
}

@MainActor
protocol WorkoutPageAppAttestProviding {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

@MainActor
private struct SystemWorkoutPageAppAttest: WorkoutPageAppAttestProviding {
    private let service = DCAppAttestService.shared
    var isSupported: Bool { service.isSupported }
    func generateKey() async throws -> String { try await service.generateKey() }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// The service serializes mutations, including assertions, so a device key's counters stay ordered.
@MainActor
final class WorkoutPageAppAttestation: WorkoutPageAttesting {
    private let baseURL: URL
    private let secureStore: WorkoutPageSecureStoring
    private let transport: WorkoutPageTransport
    private let service: WorkoutPageAppAttestProviding
    private let environment: String
    private let now: () -> Date

    init(baseURL: URL, secureStore: WorkoutPageSecureStoring, transport: @escaping WorkoutPageTransport,
         service: WorkoutPageAppAttestProviding? = nil,
         environment: String = Bundle.main.object(forInfoDictionaryKey: "BPMAppAttestEnvironment") as? String ?? "production",
         now: @escaping () -> Date = Date.init) {
        self.baseURL = baseURL
        self.secureStore = secureStore
        self.transport = transport
        self.service = service ?? SystemWorkoutPageAppAttest()
        self.environment = environment
        self.now = now
    }

    func invalidate(ownerKey: String) throws {
        try secureStore.set(Data(), for: storageKey(ownerKey))
    }

    func authorize(_ request: URLRequest, ownerKey: String) async throws -> URLRequest {
        guard service.isSupported else { throw WorkoutPageError.attestationUnavailable }
        let keyID: String
        if let stored = try secureStore.data(for: storageKey(ownerKey)), !stored.isEmpty,
           let state = try? JSONDecoder().decode(KeyState.self, from: stored), state.registered {
            keyID = state.keyID
        } else {
            keyID = try await register(ownerKey: ownerKey)
        }
        let challenge = try await challenge(purpose: "request", keyID: keyID, ownerKey: ownerKey)
        guard let url = request.url, let method = request.httpMethod else { throw WorkoutPageError.invalidResponse }
        let message = "BPM-Workout-Pages|request|\(challenge.challenge)|\(method)|\(url.path)|\(WorkoutPageCrypto.digest(request.httpBody ?? Data()))|\(WorkoutPageCrypto.digest(ownerKey))"
        let hash = Data(SHA256.hash(data: Data(message.utf8)))
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
        } catch {
            if (error as NSError).domain == DCErrorDomain, (error as NSError).code == DCError.Code.invalidKey.rawValue {
                try invalidate(ownerKey: ownerKey)
                throw WorkoutPageError.server("Device verification needs to be renewed. Please try again.", code: "ATTEST_KEY_UNKNOWN")
            }
            throw WorkoutPageError.attestationUnavailable
        }
        var authorized = request
        authorized.setValue(keyID, forHTTPHeaderField: "X-BPM-Attest-Key-ID")
        authorized.setValue(challenge.challengeID, forHTTPHeaderField: "X-BPM-Attest-Challenge-ID")
        authorized.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-BPM-Attest-Assertion")
        return authorized
    }

    private struct RegistrationBody: Codable { let challengeID: String; let keyID: String; let attestation: String }
    private struct KeyState: Codable {
        let keyID: String
        let registered: Bool
        var pendingRegistration: RegistrationBody? = nil
        var pendingChallenge: Challenge? = nil
    }
    private struct Challenge: Codable {
        let challengeID: String
        let challenge: String
        let expiresAt: String
        var requestedAt: Date? = nil
        func isFresh(at date: Date) -> Bool {
            // Use elapsed local time, not the difference between device/server clocks.
            // The server still enforces its authoritative five-minute expiration.
            guard let requestedAt else { return false }
            return date >= requestedAt && date.timeIntervalSince(requestedAt) < 300
        }
    }

    private func storageKey(_ ownerKey: String) -> String {
        "attestation.\(environment).\(WorkoutPageCrypto.digest(baseURL.absoluteString)).\(WorkoutPageCrypto.digest(ownerKey))"
    }

    private func register(ownerKey: String) async throws -> String {
        var saved = try secureStore.data(for: storageKey(ownerKey))
            .flatMap { try? JSONDecoder().decode(KeyState.self, from: $0) }
        if let saved, let pending = saved.pendingRegistration {
            try await submitRegistration(pending, ownerKey: ownerKey)
            return saved.keyID
        }
        if let pending = saved?.pendingChallenge, !pending.isFresh(at: now()) {
            // The old Apple request may already have attested this key. A different
            // challenge must use a new key, never a second attestKey call on that key.
            try invalidate(ownerKey: ownerKey)
            saved = nil
        }
        let keyID: String
        if let saved { keyID = saved.keyID }
        else {
            do {
                keyID = try await service.generateKey()
            } catch { throw WorkoutPageError.attestationUnavailable }
        }
        // Preserve the same challenge/hash when retrying Apple's serverUnavailable.
        // A failed/incomplete registration is never treated as verified.
        let challenge: Challenge
        if let pending = saved?.pendingChallenge { challenge = pending }
        else {
            try secureStore.set(try JSONEncoder().encode(KeyState(keyID: keyID, registered: false)), for: storageKey(ownerKey))
            challenge = try await self.challenge(purpose: "register", keyID: nil, ownerKey: ownerKey)
        }
        try secureStore.set(try JSONEncoder().encode(KeyState(keyID: keyID, registered: false, pendingChallenge: challenge)), for: storageKey(ownerKey))
        let message = "BPM-Workout-Pages|register|\(challenge.challenge)|\(WorkoutPageCrypto.digest(ownerKey))"
        let hash = Data(SHA256.hash(data: Data(message.utf8)))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyID, clientDataHash: hash)
        } catch {
            // Apple's temporary service failure must retry the same generated key.
            // Other failures can leave a key that is no longer usable for attestation.
            let nsError = error as NSError
            if nsError.domain != DCErrorDomain || nsError.code != DCError.Code.serverUnavailable.rawValue {
                try invalidate(ownerKey: ownerKey)
            }
            throw WorkoutPageError.attestationUnavailable
        }
        let body = RegistrationBody(challengeID: challenge.challengeID, keyID: keyID, attestation: attestation.base64EncodedString())
        try secureStore.set(try JSONEncoder().encode(KeyState(keyID: keyID, registered: false, pendingRegistration: body)), for: storageKey(ownerKey))
        try await submitRegistration(body, ownerKey: ownerKey)
        return keyID
    }

    private func submitRegistration(_ body: RegistrationBody, ownerKey: String) async throws {
        do {
            _ = try await WorkoutPageHTTP.checked(makeRequest(path: "api/workout-pages/attestation", ownerKey: ownerKey,
                                                              body: JSONEncoder().encode(body)), transport: transport)
        } catch WorkoutPageError.server(_, let code) where code == "ATTEST_CHALLENGE_EXPIRED" {
            try invalidate(ownerKey: ownerKey)
            throw WorkoutPageError.server("Device verification expired. Please try again.", code: code)
        } catch WorkoutPageError.server(let message, let code) where ["ATTESTATION_INVALID", "ATTEST_ENVIRONMENT_MISMATCH"].contains(code) {
            try invalidate(ownerKey: ownerKey)
            throw WorkoutPageError.server(message, code: code)
        }
        try secureStore.set(try JSONEncoder().encode(KeyState(keyID: body.keyID, registered: true)), for: storageKey(ownerKey))
    }

    private func challenge(purpose: String, keyID: String?, ownerKey: String) async throws -> Challenge {
        struct Body: Encodable { let purpose: String; let keyID: String? }
        let requestedAt = now()
        let data = try await WorkoutPageHTTP.checked(makeRequest(path: "api/workout-pages/challenge", ownerKey: ownerKey,
                                                                body: JSONEncoder().encode(Body(purpose: purpose, keyID: keyID))), transport: transport)
        var challenge = try JSONDecoder().decode(Challenge.self, from: data)
        guard MeasurementDateCoding.date(from: challenge.expiresAt) != nil else { throw WorkoutPageError.invalidResponse }
        challenge.requestedAt = requestedAt
        guard challenge.isFresh(at: now()) else {
            throw WorkoutPageError.server("Device verification expired. Please try again.", code: "ATTEST_CHALLENGE_EXPIRED")
        }
        return challenge
    }

    private func makeRequest(path: String, ownerKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(ownerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}
