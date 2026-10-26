import Foundation
import Testing
@testable import BPM

private final class RecapURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct WorkoutRecapTests {
    private func run(status: Int, body: String, check: @escaping (URLRequest) -> Void = { _ in }) async throws -> WorkoutRecap {
        RecapURLProtocol.handler = { request in check(request); return (status, Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecapURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); RecapURLProtocol.handler = nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("synthetic audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await WorkoutRecapClient(session: session, baseURL: URL(string: "https://example.test")!).generate(audioURL: url)
    }

    @Test func acceptsDescriptiveTitleAndDetailedNotesWithoutExtractiveRestriction() async throws {
        let result = try await run(status: 200, body: #"{"title":"Squats and push-ups","description":"3 sets of 8 squats at 62.5 kg, then 10 push-ups. Left knee felt odd; possibly 9 reps on the last set."}"#) { request in
            #expect(request.url?.path == "/api/workout-recap")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        #expect(result.title == "Squats and push-ups")
        #expect(result.description.contains("62.5 kg"))
        #expect(result.description.contains("possibly 9 reps"))
    }

    @Test func errorContractIsShownWithoutApplyingResults() async {
        do {
            _ = try await run(status: 429, body: #"{"message":"Daily limit reached","code":"DAILY_LIMIT"}"#)
            Issue.record("Should fail")
        } catch { #expect(error.localizedDescription == "Daily limit reached") }
    }

    @Test func malformedAndEmptyResponsesDoNotReplaceFields() async {
        for body in ["not json", #"{"title":"","description":"some notes"}"#, #"{"title":"Squats","description":""}"#] {
            do { _ = try await run(status: 200, body: body); Issue.record("Should reject invalid response") }
            catch { }
        }
    }
}
