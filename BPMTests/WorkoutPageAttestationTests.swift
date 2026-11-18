import XCTest
import DeviceCheck
@testable import BPM

private final class AttestationTestSecrets: WorkoutPageSecureStoring {
    var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) throws { values[key] = data }
}

@MainActor
private final class AttestationTestProvider: WorkoutPageAppAttestProviding {
    var isSupported = true
    var generatedKeys = 0
    var attestationInputs: [(String, Data)] = []
    var attestationFailures: [Error] = []
    var assertionFailure: Error?
    func generateKey() async throws -> String { generatedKeys += 1; return "key-\(generatedKeys)" }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationInputs.append((keyID, clientDataHash))
        if !attestationFailures.isEmpty { throw attestationFailures.removeFirst() }
        return Data("proof-\(keyID)".utf8)
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        if let assertionFailure { throw assertionFailure }
        return Data("signed-request".utf8)
    }
}

@MainActor
private final class AttestationTestServer {
    var now = Date(timeIntervalSince1970: 1_794_441_600)
    var registerChallenges = 0
    var requestChallenges = 0
    var registrations: [Data] = []
    var registrationError: String?
    var loseRegistrationResponse = false
    var clockOffset: TimeInterval = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        var status = 200
        let response: [String: Any]
        if url.lastPathComponent == "challenge" {
            let purpose = try XCTUnwrap(body["purpose"] as? String)
            if purpose == "register" { registerChallenges += 1 } else { requestChallenges += 1 }
            let count = registerChallenges + requestChallenges
            response = ["challengeID": "challenge-\(count)", "challenge": "random-\(count)",
                        "expiresAt": now.addingTimeInterval(300 + clockOffset).ISO8601Format()]
        } else {
            XCTAssertEqual(url.lastPathComponent, "attestation")
            registrations.append(bodyData)
            if loseRegistrationResponse {
                loseRegistrationResponse = false
                throw URLError(.networkConnectionLost)
            }
            if let registrationError {
                status = 401
                response = ["message": "Unable to verify this app installation", "code": registrationError]
            } else { response = ["success": true] }
        }
        return (try JSONSerialization.data(withJSONObject: response),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
final class WorkoutPageAttestationTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com")!
    private let ownerKey = "synthetic-owner"
    private var request: URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/workout-pages"))
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic-payload".utf8)
        return request
    }
    private func attester(_ server: AttestationTestServer, _ provider: AttestationTestProvider,
                          _ secrets: AttestationTestSecrets = AttestationTestSecrets(),
                          environment: String = "production") -> WorkoutPageAppAttestation {
        WorkoutPageAppAttestation(baseURL: baseURL, secureStore: secrets, transport: { try await server.send($0) },
                                  service: provider, environment: environment, now: { server.now })
    }
    private func unavailable(_ operation: () async throws -> URLRequest) async {
        do { _ = try await operation(); XCTFail("Unverified request must fail") }
        catch WorkoutPageError.attestationUnavailable { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAppleUnavailableRetriesTheSameKeyAndClientDataHash() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider()
        provider.attestationFailures = [NSError(domain: DCErrorDomain, code: DCError.Code.serverUnavailable.rawValue)]
        let value = attester(server, provider)
        await unavailable { try await value.authorize(self.request, ownerKey: self.ownerKey) }
        server.now.addTimeInterval(10)
        let authorized = try await value.authorize(request, ownerKey: ownerKey)
        XCTAssertEqual(provider.generatedKeys, 1)
        XCTAssertEqual(server.registerChallenges, 1)
        XCTAssertEqual(provider.attestationInputs.count, 2)
        XCTAssertEqual(provider.attestationInputs[0].0, provider.attestationInputs[1].0)
        XCTAssertEqual(provider.attestationInputs[0].1, provider.attestationInputs[1].1)
        XCTAssertNotNil(authorized.value(forHTTPHeaderField: "X-BPM-Attest-Assertion"))
    }

    func testExpiredUnfinishedAttestationGetsANewKeyAndChallenge() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider()
        provider.attestationFailures = [NSError(domain: DCErrorDomain, code: DCError.Code.serverUnavailable.rawValue)]
        let value = attester(server, provider)
        await unavailable { try await value.authorize(self.request, ownerKey: self.ownerKey) }
        server.now.addTimeInterval(301)
        _ = try await value.authorize(request, ownerKey: ownerKey)
        XCTAssertEqual(provider.generatedKeys, 2)
        XCTAssertEqual(server.registerChallenges, 2)
        XCTAssertNotEqual(provider.attestationInputs[0].0, provider.attestationInputs[1].0)
        XCTAssertNotEqual(provider.attestationInputs[0].1, provider.attestationInputs[1].1)
    }

    func testLostRegistrationResponseResubmitsProofWithoutReattesting() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider()
        server.loseRegistrationResponse = true
        let value = attester(server, provider)
        do { _ = try await value.authorize(request, ownerKey: ownerKey); XCTFail("Expected lost response") }
        catch is URLError { }
        server.now.addTimeInterval(600)
        _ = try await value.authorize(request, ownerKey: ownerKey)
        XCTAssertEqual(server.registrations.count, 2)
        let original = try JSONSerialization.jsonObject(with: server.registrations[0]) as? NSDictionary
        let retried = try JSONSerialization.jsonObject(with: server.registrations[1]) as? NSDictionary
        XCTAssertEqual(original, retried)
        XCTAssertEqual(provider.generatedKeys, 1)
        XCTAssertEqual(provider.attestationInputs.count, 1)
    }

    func testInvalidProofKeepsTheRealErrorAndDiscardsItsKey() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider(), secrets = AttestationTestSecrets()
        server.registrationError = "ATTESTATION_INVALID"
        let value = attester(server, provider, secrets)
        do { _ = try await value.authorize(request, ownerKey: ownerKey); XCTFail("Expected rejection") }
        catch WorkoutPageError.server(let message, let code) {
            XCTAssertEqual(code, "ATTESTATION_INVALID")
            XCTAssertEqual(message, "Unable to verify this app installation")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("expired"))
        }
        XCTAssertTrue(secrets.values.values.allSatisfy(\.isEmpty))
    }

    func testRegistrationKeysAreSeparatedByEnvironmentAndLegacyKeysAreNotReused() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider(), secrets = AttestationTestSecrets()
        let legacy = "attestation.\(WorkoutPageCrypto.digest(baseURL.absoluteString)).\(WorkoutPageCrypto.digest(ownerKey))"
        secrets.values[legacy] = Data("{\"keyID\":\"legacy-development-key\",\"registered\":true}".utf8)
        _ = try await attester(server, provider, secrets, environment: "production").authorize(request, ownerKey: ownerKey)
        _ = try await attester(server, provider, secrets, environment: "development").authorize(request, ownerKey: ownerKey)
        XCTAssertEqual(provider.generatedKeys, 2)
        XCTAssertEqual(server.registerChallenges, 2)
    }

    func testInvalidDeviceKeyRequestsFreshRegistration() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider(), secrets = AttestationTestSecrets()
        let value = attester(server, provider, secrets)
        _ = try await value.authorize(request, ownerKey: ownerKey)
        provider.assertionFailure = NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)
        do { _ = try await value.authorize(request, ownerKey: ownerKey); XCTFail("Expected invalid key") }
        catch WorkoutPageError.server(_, let code) { XCTAssertEqual(code, "ATTEST_KEY_UNKNOWN") }
        XCTAssertTrue(secrets.values.values.allSatisfy(\.isEmpty))
    }

    func testUnsupportedDeviceFailsClosedAndClockSkewDoesNotInventExpiry() async throws {
        let server = AttestationTestServer(), provider = AttestationTestProvider()
        let value = attester(server, provider)
        provider.isSupported = false
        await unavailable { try await value.authorize(self.request, ownerKey: self.ownerKey) }
        XCTAssertEqual(provider.generatedKeys, 0)
        XCTAssertEqual(server.registerChallenges, 0)
        provider.isSupported = true
        server.clockOffset = -3600
        _ = try await value.authorize(request, ownerKey: ownerKey)
        XCTAssertEqual(provider.generatedKeys, 1)
    }
}
