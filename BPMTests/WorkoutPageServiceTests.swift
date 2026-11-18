import XCTest
@testable import BPM

private final class WorkoutPageMemorySecrets: WorkoutPageSecureStoring {
    var values: [String: Data] = [:]
    var failWrites = false
    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) throws {
        if failWrites { throw WorkoutPageError.secureStorage }
        values[key] = data
    }
}

@MainActor
private final class WorkoutPageTestAttester: WorkoutPageAttesting {
    var fail = false
    func authorize(_ request: URLRequest, ownerKey: String) async throws -> URLRequest {
        if fail { throw WorkoutPageError.attestationUnavailable }
        var authorized = request
        authorized.setValue("test-injected-attestation", forHTTPHeaderField: "X-BPM-Attest-Assertion")
        return authorized
    }
    func invalidate(ownerKey: String) throws { }
}

@MainActor
private final class WorkoutPageMockServer {
    struct Page {
        let id: String
        let owner: String
        var viewKey: String
        var recovery: String
        var workout: WorkoutPageExport
        var version: Int
        var includesLinkCode = true
        var metadata: [String: Any] {
            var value: [String: Any] = ["pageID": id, "version": version, "createdAt": "2026-11-11T00:00:00.000Z",
             "updatedAt": "2026-11-11T00:00:00.000Z", "viewKeyRecovery": recovery]
            if includesLinkCode { value["linkCode"] = try! WorkoutPageCrypto.linkCode(viewKey: viewKey, pageID: id) }
            return value
        }
    }

    struct Stage {
        let id: String
        let page: Page
        var metadata: [String: Any] {
            page.metadata.merging(["stageID": id, "staged": true,
                                   "stageExpiresAt": "2099-11-12T00:00:00.000Z"]) { _, new in new }
        }
    }
    var pages: [String: Page] = [:]
    var stages: [String: Stage] = [:]
    var activations = 0
    var loseActivationResponse = false
    var creates = 0
    var writes = 0
    var reads = 0
    var requests = 0
    var loseCreateResponse = false
    var loseUpdateResponse = false
    var loseRotationResponse = false
    var failDelete = false
    var refuseAbsentCancellation = false
    var falseDeletionAcknowledgment = false
    var cancellations = Set<String>()
    var failReadNumber: Int?
    var beforeCreate: (() throws -> Void)?
    var beforeCreateAsync: (() async throws -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? "GET"
        let credential = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        let prefix = "/api/workout-pages"
        let suffix = String(url.path.dropFirst(prefix.count))
        let parts = suffix.split(separator: "/").map(String.init)
        let body: [String: Any]
        if let data = request.httpBody {
            let decoded = request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" ? try WorkoutPageTestFixtures.ungzip(data) : data
            body = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        } else { body = [:] }
        func response(_ object: Any, status: Int = 200) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status,
                                                                               httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func failure(_ code: String, status: Int) throws -> (Data, HTTPURLResponse) {
            try response(["error": code, "message": "Test server \(code)", "code": code], status: status)
        }
        func workout() throws -> WorkoutPageExport {
            try JSONDecoder().decode(WorkoutPageExport.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(body["workout"])))
        }

        if parts.isEmpty && method == "POST" {
            try beforeCreate?()
            try await beforeCreateAsync?()
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-BPM-Attest-Assertion"))
            let id = try XCTUnwrap(body["pageID"] as? String)
            if cancellations.contains("\(credential)|\(id)") { return try failure("PAGE_DELETED", status: 410) }
            let view = try XCTUnwrap(body["viewKey"] as? String)
            let export = try workout()
            if let page = pages[id] {
                guard page.owner == credential, page.viewKey == view, page.workout == export else { return try failure("PAGE_CONFLICT", status: 409) }
                return try response(page.metadata)
            }
            let page = Page(id: id, owner: credential, viewKey: view, recovery: try XCTUnwrap(body["viewKeyRecovery"] as? String),
                            workout: export, version: 1)
            if body["staged"] as? Bool == true {
                if let stage = stages[id], stage.page.owner == credential, stage.page.viewKey == view,
                   stage.page.recovery == page.recovery, stage.page.workout == export {
                    return try response(stage.metadata)
                }
                let stage = Stage(id: UUID().uuidString.lowercased(), page: page)
                stages[id] = stage
                creates += 1
                writes += 1
                if loseCreateResponse { loseCreateResponse = false; throw URLError(.networkConnectionLost) }
                return try response(stage.metadata)
            }
            pages[id] = page
            creates += 1
            writes += 1
            if loseCreateResponse { loseCreateResponse = false; throw URLError(.networkConnectionLost) }
            return try response(page.metadata)
        }
        if parts.isEmpty && method == "GET" {
            return try response(["pages": pages.values.filter { $0.owner == credential }.sorted { $0.id < $1.id }.map(\.metadata), "nextCursor": NSNull()])
        }
        let id = try XCTUnwrap(parts.first)
        if parts.last == "activate", method == "POST" {
            guard let stage = stages[id], stage.id == body["stageID"] as? String else {
                return try failure("STAGE_EXPIRED", status: 410)
            }
            guard stage.page.owner == credential else { return try failure("PAGE_NOT_FOUND", status: 404) }
            if pages[id]?.version != stage.page.version {
                activations += 1
                pages[id] = stage.page
            }
            if loseActivationResponse { loseActivationResponse = false; throw URLError(.networkConnectionLost) }
            return try response(stage.page.metadata)
        }
        if method == "DELETE", pages[id] == nil {
            if refuseAbsentCancellation { return try failure("PAGE_NOT_FOUND", status: 404) }
            if falseDeletionAcknowledgment { return try response(["success": false]) }
            if failDelete { throw URLError(.notConnectedToInternet) }
            cancellations.insert("\(credential)|\(id)")
            stages.removeValue(forKey: id)
            return try response(["success": true])
        }
        guard var page = pages[id] else { return try failure("PAGE_NOT_FOUND", status: 404) }
        if method == "GET" {
            guard page.viewKey == credential else { return try failure("PAGE_NOT_FOUND", status: 404) }
            reads += 1
            if reads == failReadNumber { throw URLError(.notConnectedToInternet) }
            return (try page.workout.encoded(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        guard page.owner == credential else { return try failure("PAGE_NOT_FOUND", status: 404) }
        if method == "DELETE" {
            if failDelete { throw URLError(.notConnectedToInternet) }
            pages.removeValue(forKey: id)
            cancellations.insert("\(credential)|\(id)")
            return try response(["success": true])
        }
        guard (body["expectedVersion"] as? Int) == page.version else { return try failure("PAGE_CONFLICT", status: 409) }
        if method == "PUT" {
            page.workout = try workout()
            page.version += 1
            pages[id] = page
            writes += 1
            if loseUpdateResponse { loseUpdateResponse = false; throw URLError(.networkConnectionLost) }
            return try response(page.metadata)
        }
        if parts.last == "rotate" && method == "POST" {
            page.viewKey = try XCTUnwrap(body["viewKey"] as? String)
            page.recovery = try XCTUnwrap(body["viewKeyRecovery"] as? String)
            page.version += 1
            pages[id] = page
            if loseRotationResponse { loseRotationResponse = false; throw URLError(.networkConnectionLost) }
            return try response(page.metadata)
        }
        return try failure("UNKNOWN_ROUTE", status: 400)
    }
}

@MainActor
final class WorkoutPageServiceTests: XCTestCase {
    private let serverURL = URL(string: "https://bpm.test")!

    private func registryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bpm-page-tests-\(UUID())/registry.json")
    }

    private func service(server: WorkoutPageMockServer, secrets: WorkoutPageMemorySecrets = WorkoutPageMemorySecrets(),
                         registry: URL? = nil, attester: WorkoutPageTestAttester? = nil) -> WorkoutPageService {
        WorkoutPageService(baseURL: serverURL, registryURL: registry ?? registryURL(), secureStore: secrets,
                           transport: { try await server.send($0) }, attester: attester ?? WorkoutPageTestAttester())
    }

    private func share(_ service: WorkoutPageService, record: WorkoutRecord, title: String = "Shared training",
                       update: Bool = false) async throws -> URL {
        try await service.prepareShare(record: record, title: title, description: "Shared private description",
                                       includeDate: false, updateExisting: update)
    }

    private func assertPublishedLink(_ url: URL, replacing pendingURL: URL, service: WorkoutPageService,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(service.entries.first?.id, pendingURL.lastPathComponent, file: file, line: line)
        XCTAssertEqual(url.fragment, pendingURL.fragment, file: file, line: line)
        XCTAssertNil(url.query, file: file, line: line)
        XCTAssertEqual(url.lastPathComponent,
                       try WorkoutPageCrypto.linkCode(viewKey: XCTUnwrap(url.fragment), pageID: pendingURL.lastPathComponent),
                       file: file, line: line)
    }

    func testPreviewTokenMatchesServerVectorAndIsBoundToPageAndViewKey() throws {
        let viewKey = String(repeating: "A", count: 43)
        let pageID = "11111111-1111-4111-8111-111111111111"
        let token = try WorkoutPageCrypto.previewToken(viewKey: viewKey, pageID: pageID)
        XCTAssertEqual(token, "U1TUNiJYjihwjgiN76XDJIBul9E8PhR7xHQSljF-jZ4")
        XCTAssertNotEqual(token, viewKey)
        XCTAssertNotEqual(token, try WorkoutPageCrypto.previewToken(viewKey: viewKey, pageID: UUID().uuidString.lowercased()))
        XCTAssertNotEqual(token, try WorkoutPageCrypto.previewToken(viewKey: WorkoutPageCrypto.randomSecret(), pageID: pageID))
        XCTAssertThrowsError(try WorkoutPageCrypto.previewToken(viewKey: "invalid", pageID: pageID))
        let code = try WorkoutPageCrypto.linkCode(viewKey: viewKey, pageID: pageID)
        XCTAssertEqual(code, "eReZrdBGAlQEUvbRHgNVQg")
        XCTAssertEqual(WorkoutPageCrypto.decodeBase64URL(code)?.count, 16)
        XCTAssertNotEqual(code, try WorkoutPageCrypto.linkCode(viewKey: viewKey, pageID: UUID().uuidString.lowercased()))
        XCTAssertNotEqual(code, try WorkoutPageCrypto.linkCode(viewKey: WorkoutPageCrypto.randomSecret(), pageID: pageID))
        XCTAssertThrowsError(try WorkoutPageCrypto.linkCode(viewKey: "invalid", pageID: pageID))
    }

    func testLegacyServerFallbackAndRefreshUpgradeKeepTheSameWorkoutAndViewKey() async throws {
        let server = WorkoutPageMockServer()
        let secrets = WorkoutPageMemorySecrets()
        let disk = registryURL()
        let service = service(server: server, secrets: secrets, registry: disk)
        let record = WorkoutPageTestFixtures.record()
        let short = try await share(service, record: record)
        let id = try XCTUnwrap(service.entries.first?.id)
        server.pages[id]?.includesLinkCode = false
        let legacy = try await share(service, record: record)
        XCTAssertEqual(legacy.lastPathComponent, id)
        XCTAssertEqual(legacy.fragment, short.fragment)
        XCTAssertEqual(URLComponents(url: legacy, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value,
                       try WorkoutPageCrypto.previewToken(viewKey: XCTUnwrap(legacy.fragment), pageID: id))
        let restored = self.service(server: server, secrets: secrets, registry: disk)
        XCTAssertEqual(restored.entries.first?.pageURL, legacy)
        server.pages[id]?.includesLinkCode = true
        let upgraded = try await share(restored, record: record)
        XCTAssertEqual(upgraded, short)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(server.pages[id]?.version, 1)
        XCTAssertEqual(self.service(server: server, secrets: secrets, registry: disk).entries.first?.pageURL, short)
    }

    func testBackgroundUploadIsInaccessibleUntilExplicitShare() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        try await service.stageShare(record: record, title: "Shared training", description: "Shared private description", includeDate: false)
        XCTAssertTrue(server.pages.isEmpty)
        XCTAssertEqual(server.stages.count, 1)
        XCTAssertEqual(server.activations, 0)
        XCTAssertEqual(service.entries.first?.status, .pending)
        let stagedURL = try XCTUnwrap(service.entries.first?.pageURL)
        try await service.stageShare(record: record, title: "Shared training", description: "Shared private description", includeDate: false)
        XCTAssertEqual(server.writes, 1)
        let url = try await share(service, record: record)
        try assertPublishedLink(url, replacing: stagedURL, service: service)
        XCTAssertEqual(server.activations, 1)
        XCTAssertEqual(server.writes, 1)
        XCTAssertEqual(service.entries.first?.status, .published)
    }

    func testExpiredBackgroundUploadRestagesAndActivatesOnce() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        try await service.stageShare(record: record, title: "Shared training", description: "Shared private description", includeDate: false)
        let url = try XCTUnwrap(service.entries.first?.pageURL)
        server.stages.removeAll()
        let result = try await share(service, record: record)
        try assertPublishedLink(result, replacing: url, service: service)
        XCTAssertEqual(server.activations, 1)
        XCTAssertEqual(server.writes, 2)
    }

    func testChangedUnpublishedDraftReplacesOldSnapshotBeforeActivation() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        try await service.stageShare(record: record, title: "Original title", description: "Shared private description", includeDate: false)
        let originalURL = try XCTUnwrap(service.entries.first?.pageURL)
        let originalStageID = try XCTUnwrap(server.stages.values.first?.id)

        try await service.stageShare(record: record, title: "Updated saved title", description: "Shared private description", includeDate: false)
        XCTAssertTrue(server.pages.isEmpty)
        XCTAssertEqual(server.activations, 0)
        XCTAssertEqual(server.stages.count, 1)
        XCTAssertNotEqual(server.stages.values.first?.id, originalStageID)
        XCTAssertEqual(server.stages.values.first?.page.workout.title, "Updated saved title")
        XCTAssertEqual(service.entries.first?.pageURL, originalURL)
        XCTAssertEqual(service.entries.first?.title, "Updated saved title")
        XCTAssertEqual(service.entries.first?.status, .pending)

        let url = try await share(service, record: record, title: "Updated saved title")
        try assertPublishedLink(url, replacing: originalURL, service: service)
        XCTAssertEqual(server.activations, 1)
        XCTAssertEqual(server.pages.values.first?.workout.title, "Updated saved title")
        XCTAssertEqual(server.writes, 2)
    }

    func testStagedUploadSurvivesRestartWithoutPublishingAndLostActivationRecovers() async throws {
        let server = WorkoutPageMockServer()
        let secrets = WorkoutPageMemorySecrets()
        let disk = registryURL()
        let original = service(server: server, secrets: secrets, registry: disk)
        let record = WorkoutPageTestFixtures.record()
        try await original.stageShare(record: record, title: "Shared training", description: "Shared private description", includeDate: false)
        let restarted = service(server: server, secrets: secrets, registry: disk)
        try await restarted.refresh()
        XCTAssertTrue(server.pages.isEmpty)
        XCTAssertEqual(restarted.entries.first?.status, .pending)
        server.loseActivationResponse = true
        do { _ = try await share(restarted, record: record); XCTFail("Expected injected lost response") } catch { }
        let recovered = try await share(restarted, record: record)
        try assertPublishedLink(recovered, replacing: XCTUnwrap(original.entries.first?.pageURL), service: restarted)
        XCTAssertEqual(server.activations, 1)
        XCTAssertEqual(server.writes, 1)
    }

    func testShareWaitsForBackgroundUploadThenActivatesWithoutAnotherUpload() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let draft = WorkoutPageShareDraft(record: WorkoutPageTestFixtures.record(), service: service)
        let uploadStarted = expectation(description: "Background upload started")
        var releaseUpload: CheckedContinuation<Void, Never>?
        server.beforeCreateAsync = {
            await withCheckedContinuation { continuation in
                releaseUpload = continuation
                uploadStarted.fulfill()
            }
        }
        draft.includesPage = true
        await fulfillment(of: [uploadStarted], timeout: 2)
        var sharedURL: URL?
        draft.prepareShare { sharedURL = $0 }
        XCTAssertTrue(draft.isPreparingShare)
        XCTAssertEqual(draft.uploadStatusText, "Uploading workout…")
        XCTAssertNil(sharedURL)
        XCTAssertEqual(server.activations, 0)
        releaseUpload?.resume()
        while draft.isPreparingShare { await Task.yield() }
        XCTAssertNotNil(sharedURL)
        XCTAssertEqual(server.writes, 1)
        XCTAssertEqual(server.activations, 1)
        XCTAssertNil(draft.errorMessage)
    }

    func testUncheckingOrClosingDraftDoesNotActivateBackgroundUpload() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let draft = WorkoutPageShareDraft(record: WorkoutPageTestFixtures.record(), service: service)
        draft.includesPage = true
        while draft.isUploading { await Task.yield() }
        XCTAssertEqual(server.stages.count, 1)
        draft.includesPage = false
        draft.cancel()
        draft.prepareShare { XCTAssertNil($0) }
        XCTAssertTrue(server.pages.isEmpty)
        XCTAssertEqual(server.activations, 0)
    }

    func testCancelOrUncheckDuringFinalRetryUploadDoesNotActivate() async throws {
        for closeDraft in [true, false] {
            let server = WorkoutPageMockServer()
            let attester = WorkoutPageTestAttester()
            attester.fail = true
            let service = service(server: server, attester: attester)
            let draft = WorkoutPageShareDraft(record: WorkoutPageTestFixtures.record(), service: service)
            draft.includesPage = true
            while draft.isUploading { await Task.yield() }
            XCTAssertTrue(server.stages.isEmpty)

            attester.fail = false
            let uploadStarted = expectation(description: "Final retry reached the upload")
            var releaseUpload: CheckedContinuation<Void, Never>?
            server.beforeCreateAsync = {
                await withCheckedContinuation { continuation in
                    releaseUpload = continuation
                    uploadStarted.fulfill()
                }
            }
            var shared = false
            draft.prepareShare { _ in shared = true }
            await fulfillment(of: [uploadStarted], timeout: 2)
            XCTAssertTrue(draft.isPreparingShare)
            if closeDraft { draft.cancel() }
            else { draft.includesPage = false }
            releaseUpload?.resume()
            while draft.isPreparingShare { await Task.yield() }

            XCTAssertFalse(shared)
            XCTAssertEqual(server.stages.count, 1)
            XCTAssertTrue(server.pages.isEmpty)
            XCTAssertEqual(server.activations, 0)
        }
    }

    func testCredentialsAndEncryptedPendingBodyAreDurableBeforeUploadAndReshareReusesPage() async throws {
        let server = WorkoutPageMockServer()
        let secrets = WorkoutPageMemorySecrets()
        let disk = registryURL()
        let service = service(server: server, secrets: secrets, registry: disk)
        server.beforeCreate = {
            XCTAssertFalse(secrets.values.isEmpty)
            let encrypted = try String(contentsOf: disk, encoding: .utf8)
            XCTAssertFalse(encrypted.contains("Shared training"))
            XCTAssertFalse(encrypted.contains("Shared private description"))
            XCTAssertTrue(encrypted.contains("pending"))
        }
        let record = WorkoutPageTestFixtures.record()
        let url = try await share(service, record: record)
        XCTAssertEqual(url.fragment?.count, 43)
        XCTAssertNil(url.query)
        XCTAssertEqual(url.lastPathComponent.count, 22)
        XCTAssertEqual(url.lastPathComponent,
                       try WorkoutPageCrypto.linkCode(viewKey: XCTUnwrap(url.fragment), pageID: XCTUnwrap(service.entries.first?.id)))
        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries[0].status, .published)
        XCTAssertNotEqual(server.pages.values.first?.owner, url.fragment)
        let same = try await share(service, record: record)
        XCTAssertEqual(url, same)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(server.writes, 1)
        let encrypted = try String(contentsOf: disk, encoding: .utf8)
        XCTAssertFalse(encrypted.contains(try XCTUnwrap(url.fragment)))
        XCTAssertFalse(encrypted.contains(url.lastPathComponent))
    }

    func testChangedSnapshotRequiresExplicitUpdateAndKeepsStableURL() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        let url = try await share(service, record: record)
        do {
            _ = try await share(service, record: record, title: "New title")
            XCTFail("Changing shared content requires an explicit update")
        } catch WorkoutPageError.updateRequired { }
        XCTAssertEqual(server.writes, 1)
        let updated = try await share(service, record: record, title: "New title", update: true)
        XCTAssertEqual(updated, url)
        XCTAssertEqual(server.pages.values.first?.workout.title, "New title")
        XCTAssertEqual(service.entries[0].title, "New title")
        XCTAssertEqual(server.writes, 2)
    }

    func testLostCreateResponseRecoversSamePageAfterProcessRestart() async throws {
        let server = WorkoutPageMockServer()
        let secrets = WorkoutPageMemorySecrets()
        let disk = registryURL()
        let original = service(server: server, secrets: secrets, registry: disk)
        let record = WorkoutPageTestFixtures.record()
        server.loseCreateResponse = true
        do { _ = try await share(original, record: record); XCTFail("Injected failure expected") } catch { }
        XCTAssertEqual(original.entries[0].status, .pending)
        let pendingURL = original.entries[0].pageURL
        let restarted = service(server: server, secrets: secrets, registry: disk)
        let result = try await share(restarted, record: record)
        try assertPublishedLink(result, replacing: pendingURL, service: restarted)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(restarted.entries[0].status, .published)
    }

    func testLostUpdateResponseReconcilesVersionConflictWithoutDuplicateMutation() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        let url = try await share(service, record: record)
        server.loseUpdateResponse = true
        do { _ = try await share(service, record: record, title: "Updated", update: true); XCTFail("Injected failure expected") } catch { }
        let retried = try await share(service, record: record, title: "Updated", update: true)
        XCTAssertEqual(retried, url)
        XCTAssertEqual(service.entries[0].title, "Updated")
        XCTAssertEqual(server.writes, 2)
    }

    func testRecoveryRestoresSameViewLinkAndRotationInvalidatesOldLink() async throws {
        let server = WorkoutPageMockServer()
        let original = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        let url = try await share(original, record: record)
        let code = try original.exportRecoveryCode()
        let restored = service(server: server)
        try await restored.restoreRecoveryCode(code)
        XCTAssertEqual(restored.entries[0].pageURL, url)
        XCTAssertEqual(restored.entries[0].description, "Shared private description")
        XCTAssertEqual(restored.entries[0].localWorkoutID, record.id)
        let rotated = try await restored.rotateLink(restored.entries[0])
        XCTAssertNotEqual(rotated.path, url.path)
        XCTAssertNotEqual(rotated.fragment, url.fragment)
        XCTAssertEqual(server.pages.values.first?.viewKey, rotated.fragment)
        let again = service(server: server)
        try await again.restoreRecoveryCode(code)
        XCTAssertEqual(again.entries[0].pageURL, rotated)
    }

    func testPublishedCalendarDaySurvivesResharingRecoveryAndDetailsEdits() async throws {
        let server = WorkoutPageMockServer()
        let original = service(server: server)
        let start = try XCTUnwrap(MeasurementDateCoding.date(from: "2026-11-12T01:30:00.000Z"))
        let record = WorkoutPageTestFixtures.record(startAt: start)
        // Choose the adjacent valid timezone day, so this proves re-sharing does not
        // silently replace the originally reviewed date with today's device timezone.
        let publishedDate = WorkoutPageDate.string(from: start) == "2026-11-11" ? "2026-11-12" : "2026-11-11"
        let url = try await original.prepareShare(record: record, title: "Shared training", description: "Shared private description",
                                                 includeDate: false, workoutDate: publishedDate)
        let reshared = try await share(original, record: record)
        XCTAssertEqual(reshared, url)
        XCTAssertEqual(server.writes, 1)
        let restored = service(server: server)
        try await restored.restoreRecoveryCode(original.exportRecoveryCode())
        XCTAssertEqual(restored.entries.first?.workoutDate, publishedDate)
        XCTAssertEqual(restored.entries.first?.includeDate, false)
        try await restored.updateDetails(restored.entries[0], title: "New description title", description: "Updated description")
        XCTAssertEqual(server.pages.values.first?.workout.workoutDate, publishedDate)
        XCTAssertNil(server.pages.values.first?.workout.recordedAt)
        XCTAssertEqual(restored.entries.first?.workoutDate, publishedDate)
    }

    func testRecoveryMergesOwnersAndItsExportBacksUpBoth() async throws {
        let server = WorkoutPageMockServer()
        let first = service(server: server)
        let second = service(server: server)
        let firstURL = try await share(first, record: WorkoutPageTestFixtures.record(), title: "First owner")
        let secondURL = try await share(second, record: WorkoutPageTestFixtures.record(), title: "Second owner")
        try await second.restoreRecoveryCode(first.exportRecoveryCode())
        XCTAssertEqual(Set(second.entries.map(\.pageURL)), Set([firstURL, secondURL]))
        let third = service(server: server)
        try await third.restoreRecoveryCode(second.exportRecoveryCode())
        XCTAssertEqual(Set(third.entries.map(\.pageURL)), Set([firstURL, secondURL]))
        for entry in third.entries { try await third.delete(entry) }
        XCTAssertTrue(server.pages.isEmpty)
    }

    func testReshareReconcilesLinkRotationFromAnotherRecoveredDevice() async throws {
        let server = WorkoutPageMockServer()
        let original = service(server: server)
        let record = WorkoutPageTestFixtures.record()
        let oldURL = try await share(original, record: record)
        let recovered = service(server: server)
        try await recovered.restoreRecoveryCode(original.exportRecoveryCode())
        let currentURL = try await recovered.rotateLink(recovered.entries[0])
        let reshared = try await share(original, record: record)
        XCTAssertNotEqual(reshared, oldURL)
        XCTAssertEqual(reshared, currentURL)
        XCTAssertEqual(server.creates, 1)
    }

    func testLostRotationResponseRetryDoesNotReplaceTheLinkTwice() async throws {
        let server = WorkoutPageMockServer()
        let service = service(server: server)
        _ = try await share(service, record: WorkoutPageTestFixtures.record())
        server.loseRotationResponse = true
        do { _ = try await service.rotateLink(service.entries[0]); XCTFail("Injected failure expected") } catch { }
        let currentKey = try XCTUnwrap(server.pages.values.first?.viewKey)
        let recovered = try await service.rotateLink(service.entries[0])
        XCTAssertEqual(recovered.fragment, currentKey)
        XCTAssertEqual(server.pages.values.first?.version, 2)
    }

    func testDeletionAndDetailsStillWorkWithoutTheLocalWorkout() async throws {
        let server = WorkoutPageMockServer()
        let original = service(server: server)
        _ = try await share(original, record: WorkoutPageTestFixtures.record())
        let restored = service(server: server)
        try await restored.restoreRecoveryCode(original.exportRecoveryCode())
        try await restored.updateDetails(restored.entries[0], title: "Edited after recovery", description: "New description")
        XCTAssertEqual(server.pages.values.first?.workout.title, "Edited after recovery")
        server.failDelete = true
        do { try await restored.delete(restored.entries[0]); XCTFail("Injected failure expected") } catch { }
        try await restored.refresh()
        server.failDelete = false
        try await restored.delete(restored.entries[0])
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(server.pages.isEmpty)
    }

    func testFailedAttestationCanDeleteNeverUploadedPendingPage() async throws {
        let server = WorkoutPageMockServer()
        let attester = WorkoutPageTestAttester()
        attester.fail = true
        let service = service(server: server, attester: attester)
        do { _ = try await share(service, record: WorkoutPageTestFixtures.record()); XCTFail("Verification must be required") }
        catch WorkoutPageError.attestationUnavailable { }
        XCTAssertEqual(server.creates, 0)
        XCTAssertEqual(service.entries.count, 1)
        try await service.delete(service.entries[0])
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testPendingSnapshotCanRetryWithoutTheOriginalWorkout() async throws {
        let server = WorkoutPageMockServer()
        let attester = WorkoutPageTestAttester()
        attester.fail = true
        let service = service(server: server, attester: attester)
        do { _ = try await share(service, record: WorkoutPageTestFixtures.record()); XCTFail("Injected failure expected") } catch { }
        let pending = try XCTUnwrap(service.entries.first)
        attester.fail = false
        let link = try await service.retryPendingUpload(pending)
        try assertPublishedLink(link, replacing: pending.pageURL, service: service)
        XCTAssertEqual(server.creates, 1)
        XCTAssertEqual(service.entries.first?.status, .published)
    }

    func testUnacknowledgedDeletionKeepsPendingEntryAndItsCredentials() async throws {
        let server = WorkoutPageMockServer()
        let attester = WorkoutPageTestAttester()
        attester.fail = true
        let service = service(server: server, attester: attester)
        do { _ = try await share(service, record: WorkoutPageTestFixtures.record()); XCTFail("Injected failure expected") } catch { }
        let pending = try XCTUnwrap(service.entries.first)
        server.refuseAbsentCancellation = true
        do {
            try await service.delete(pending)
            XCTFail("An absent page is not an acknowledged cancellation of an in-flight create")
        } catch WorkoutPageError.server(_, let code) {
            XCTAssertEqual(code, "PAGE_NOT_FOUND")
        }
        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries.first?.pageURL, pending.pageURL)
        XCTAssertEqual(service.entries.first?.status, .pending)
        XCTAssertEqual(service.entries.first?.hasPendingDeletion, true)
        server.refuseAbsentCancellation = false
        server.falseDeletionAcknowledgment = true
        do {
            try await service.delete(pending)
            XCTFail("Only an explicit positive acknowledgment can clear deletion authority")
        } catch WorkoutPageError.invalidResponse { }
        XCTAssertEqual(service.entries.count, 1)
        server.falseDeletionAcknowledgment = false
        try await service.delete(pending)
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(server.cancellations.count, 1)
    }

    func testKeychainFailurePreventsAnyUpload() async throws {
        let server = WorkoutPageMockServer()
        let secrets = WorkoutPageMemorySecrets()
        secrets.failWrites = true
        let service = service(server: server, secrets: secrets)
        do { _ = try await share(service, record: WorkoutPageTestFixtures.record()); XCTFail("Key persistence is required") }
        catch WorkoutPageError.secureStorage { }
        XCTAssertEqual(server.requests, 0)
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testRecoveryKeepsProgressAcrossMidArchiveReadFailure() async throws {
        let server = WorkoutPageMockServer()
        let original = service(server: server)
        for index in 0..<3 { _ = try await share(original, record: WorkoutPageTestFixtures.record(), title: "Workout \(index)") }
        let restored = service(server: server)
        server.failReadNumber = 2
        do { try await restored.restoreRecoveryCode(original.exportRecoveryCode()); XCTFail("Injected failure expected") } catch { }
        XCTAssertEqual(restored.entries.count, 1)
        server.failReadNumber = nil
        try await restored.refresh()
        XCTAssertEqual(restored.entries.count, 3)
        XCTAssertEqual(server.reads, 4) // First success, failed second, then only the two missing pages.
    }

    func testEncryptedEnvelopeRejectsTamperingAndDifferentPageContext() throws {
        let root = try WorkoutPageCrypto.randomSecret()
        let plaintext = Data("test view-key material".utf8)
        let sealed = try WorkoutPageCrypto.seal(plaintext, root: root, context: "view:page-one")
        XCTAssertEqual(try WorkoutPageCrypto.open(sealed, root: root, context: "view:page-one"), plaintext)
        XCTAssertThrowsError(try WorkoutPageCrypto.open(sealed, root: root, context: "view:page-two"))
        var bytes = try XCTUnwrap(WorkoutPageCrypto.decodeBase64URL(sealed))
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try WorkoutPageCrypto.open(WorkoutPageCrypto.base64URL(bytes), root: root, context: "view:page-one"))
        XCTAssertNotEqual(try WorkoutPageCrypto.derive(root: root, purpose: "registry-encryption"),
                          try WorkoutPageCrypto.derive(root: root, purpose: "management-authority"))
    }
}
