import Foundation
import Combine

struct WorkoutPageEntry: Identifiable, Equatable {
    enum Status: String, Codable { case pending, published }
    let id: String
    let pageURL: URL
    let title: String
    let description: String
    let includeDate: Bool
    let workoutDate: String?
    let localWorkoutID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let status: Status
    let version: Int
    let hasPendingDeletion: Bool
}

/// Page ownership outlives the workout history. Secrets are held in Keychain; the
/// on-disk registry and pending requests are encrypted under those secrets.
@MainActor
final class WorkoutPageService: ObservableObject {
    static let shared = WorkoutPageService()

    @Published private(set) var entries: [WorkoutPageEntry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private struct Vault: Codable {
        var roots: [String]
    }

    private struct Registry: Codable {
        var schemaVersion = 1
        var pages: [StoredPage]
    }

    private struct StoredPage: Codable {
        let id: String
        let ownerID: String
        var version: Int
        var createdAt: Date
        var updatedAt: Date
        var status: WorkoutPageEntry.Status
        var viewKeyRecovery: String
        var encryptedState: String
        var usesShortLink: Bool? = nil
    }

    private struct LocalState: Codable {
        var viewKey: String
        var localWorkoutID: UUID?
        var title: String
        var description: String
        var includeDate: Bool
        var workoutDate: String? = nil
        var fingerprint: String
        var pending: Pending?
    }

    private struct Pending: Codable {
        enum Kind: String, Codable { case create, update, rotate, delete }
        let kind: Kind
        let body: Data?
        let workout: WorkoutPageExport?
        let newViewKey: String?
        let newViewKeyRecovery: String?
        var staged: Bool? = nil
        var stageID: String? = nil
    }

    private struct RecoveryEnvelope: Codable {
        let viewKey: String
        let localWorkoutID: UUID?
    }

    private struct RecoveryCode: Codable {
        let version: Int
        let origin: String
        let roots: [String]
    }

    private struct Metadata: Decodable {
        let pageID: String
        let version: Int
        let createdAt: String
        let updatedAt: String
        let viewKeyRecovery: String
        let stageID: String?
        let linkCode: String?
    }

    private struct Listing: Decodable {
        let pages: [Metadata]
        let nextCursor: String?
    }

    private struct CreateBody: Encodable {
        let pageID: String
        let viewKey: String
        let viewKeyRecovery: String
        let workout: WorkoutPageExport
        var staged: Bool? = nil
    }

    private struct UpdateBody: Encodable {
        let expectedVersion: Int
        let workout: WorkoutPageExport
        var staged: Bool? = nil
    }

    private struct RotateBody: Encodable {
        let expectedVersion: Int
        let viewKey: String
        let viewKeyRecovery: String
    }

    private let baseURL: URL
    private let registryURL: URL
    private let secureStore: WorkoutPageSecureStoring
    private let transport: WorkoutPageTransport
    private let attester: WorkoutPageAttesting
    private var vault = Vault(roots: [])
    private var registry = Registry(pages: [])
    private var initializationError: Error?

    init(baseURL: URL? = nil, registryURL: URL? = nil,
         secureStore: WorkoutPageSecureStoring = WorkoutPageKeychain(),
         transport: @escaping WorkoutPageTransport = WorkoutPageHTTP.transport,
         attester: WorkoutPageAttesting? = nil) {
        let configured = UserDefaults.standard.string(forKey: "BPM_API_BASE_URL")
        let server = baseURL ?? configured.flatMap(URL.init(string:)) ?? URL(string: "https://bpmtracker.app")!
        self.baseURL = server
        self.registryURL = registryURL ?? Self.defaultRegistryURL()
        self.secureStore = secureStore
        self.transport = transport
        self.attester = attester ?? WorkoutPageAppAttestation(baseURL: server, secureStore: secureStore, transport: transport)
        do {
            if let data = try secureStore.data(for: vaultKey) {
                vault = try JSONDecoder().decode(Vault.self, from: data)
                for root in vault.roots { _ = try WorkoutPageCrypto.ownerID(root: root) }
            }
            if FileManager.default.fileExists(atPath: self.registryURL.path) {
                registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: self.registryURL))
                guard registry.schemaVersion == 1 else { throw WorkoutPageError.localStorage }
            }
            try publishEntries()
        } catch {
            initializationError = error
            lastError = error.localizedDescription
        }
    }

    func entry(for workoutID: UUID) -> WorkoutPageEntry? {
        entries.first { $0.localWorkoutID == workoutID }
    }

    /// Upload privately after the user opts in. This never activates a new page
    /// or changes the contents of a page that recipients can already view.
    func stageShare(record: WorkoutRecord, title: String, description: String,
                    includeDate: Bool, workoutDate: String? = nil) async throws {
        _ = try await prepare(record: record, title: title, description: description,
                              includeDate: includeDate, workoutDate: workoutDate,
                              updateExisting: false, activate: false)
    }

    /// Only the final, explicit Share action activates a staged upload.
    func prepareShare(record: WorkoutRecord, title: String, description: String,
                      includeDate: Bool, workoutDate: String? = nil, updateExisting: Bool = false) async throws -> URL {
        try await prepare(record: record, title: title, description: description,
                          includeDate: includeDate, workoutDate: workoutDate,
                          updateExisting: updateExisting, activate: true)
    }

    private func prepare(record: WorkoutRecord, title: String, description: String,
                         includeDate: Bool, workoutDate: String?, updateExisting: Bool,
                         activate: Bool) async throws -> URL {
        try beginOperation()
        defer { isWorking = false }
        var workout = try WorkoutPageExport(record: record, title: title, description: description, includeDate: includeDate)

        // Another recovered installation may have rotated, edited, or deleted the
        // page. Never silently share a stale link or a snapshot unlike the preview.
        if let local = entry(for: record.id), let stored = registry.pages.first(where: { $0.id == local.id }) {
            try await refreshOwner(ownerRoot(for: stored))
        }
        if let date = workoutDate ?? entry(for: record.id)?.workoutDate {
            guard WorkoutPageDate.date(from: date) != nil else { throw WorkoutPageError.invalidWorkout("This workout has an unsupported date.") }
            workout.workoutDate = date
        }
        let fingerprint = try fingerprint(workout)

        if let entry = entry(for: record.id), let index = registry.pages.firstIndex(where: { $0.id == entry.id }) {
            let root = try ownerRoot(for: registry.pages[index])
            var state = try localState(registry.pages[index], root: root)
            // An abandoned upload has never been shared. Replace that private
            // snapshot directly, without briefly activating its outdated content.
            if registry.pages[index].status == .pending, state.pending?.kind == .create,
               state.pending?.staged == true,
               try state.pending?.workout.map({ try self.fingerprint($0) }) != fingerprint {
                let body = try WorkoutPageExport.encoder().encode(CreateBody(
                    pageID: entry.id, viewKey: state.viewKey,
                    viewKeyRecovery: registry.pages[index].viewKeyRecovery, workout: workout, staged: true
                ))
                _ = try WorkoutPageCompression.gzip(body)
                state.title = workout.title
                state.description = workout.description ?? ""
                state.includeDate = workout.recordedAt != nil
                state.workoutDate = workout.workoutDate
                state.fingerprint = fingerprint
                state.pending = Pending(kind: .create, body: body, workout: workout,
                                        newViewKey: nil, newViewKeyRecovery: nil, staged: true)
                try storeState(state, page: registry.pages[index], root: root)
            }
            let intendedFingerprint = try state.pending?.workout.map { try self.fingerprint($0) } ?? state.fingerprint
            guard updateExisting || intendedFingerprint == fingerprint else { throw WorkoutPageError.updateRequired }
            if state.pending != nil {
                try await finishPending(pageID: entry.id, activate: activate)
            }
            guard let refreshed = registry.pages.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.missingPage }
            state = try localState(refreshed, root: root)
            if state.fingerprint != fingerprint {
                guard updateExisting else { throw WorkoutPageError.updateRequired }
                try stageUpdate(page: refreshed, root: root, state: state, workout: workout, staged: !activate)
                try await finishPending(pageID: refreshed.id, activate: activate)
            }
            guard let result = entries.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.invalidResponse }
            return result.pageURL
        }

        let root = try activeRoot()
        let pageID = UUID().uuidString.lowercased()
        let viewKey = try WorkoutPageCrypto.randomSecret()
        let envelope = try recoveryEnvelope(viewKey: viewKey, localWorkoutID: record.id, root: root, pageID: pageID)
        let body = try WorkoutPageExport.encoder().encode(CreateBody(pageID: pageID, viewKey: viewKey,
                                                                   viewKeyRecovery: envelope, workout: workout, staged: activate ? nil : true))
        // Validate both limits before creating a pending entry or making any request.
        _ = try WorkoutPageCompression.gzip(body)
        let state = LocalState(viewKey: viewKey, localWorkoutID: record.id, title: workout.title,
                               description: workout.description ?? "", includeDate: workout.recordedAt != nil,
                               workoutDate: workout.workoutDate,
                               fingerprint: fingerprint,
                               pending: Pending(kind: .create, body: body, workout: workout, newViewKey: nil, newViewKeyRecovery: nil, staged: activate ? nil : true))
        let now = Date()
        let page = StoredPage(id: pageID, ownerID: try WorkoutPageCrypto.ownerID(root: root), version: 0,
                              createdAt: now, updatedAt: now, status: .pending, viewKeyRecovery: envelope,
                              encryptedState: try sealState(state, root: root, pageID: pageID))
        var next = registry
        next.pages.append(page)
        try persist(next)
        try await finishPending(pageID: pageID, activate: activate)
        guard let result = entries.first(where: { $0.id == pageID }) else { throw WorkoutPageError.invalidResponse }
        return result.pageURL
    }

    func updateDetails(_ entry: WorkoutPageEntry, title: String, description: String) async throws {
        try beginOperation()
        defer { isWorking = false }
        try await finishPending(pageID: entry.id)
        guard let page = registry.pages.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.missingPage }
        let root = try ownerRoot(for: page)
        let state = try localState(page, root: root)
        var workout = try await fetchWorkout(pageID: page.id, viewKey: state.viewKey)
        try workout.setDetails(title: title, description: description)
        if try fingerprint(workout) == state.fingerprint { return }
        try stageUpdate(page: page, root: root, state: state, workout: workout)
        try await finishPending(pageID: page.id)
    }

    /// Retry the reviewed snapshot saved before an interrupted upload, even when
    /// the original workout has since been pruned from local history.
    func retryPendingUpload(_ entry: WorkoutPageEntry) async throws -> URL {
        try beginOperation()
        defer { isWorking = false }
        guard let page = registry.pages.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.missingPage }
        let state = try localState(page, root: ownerRoot(for: page))
        guard page.status == .pending, state.pending?.kind == .create else { throw WorkoutPageError.updateRequired }
        try await finishPending(pageID: entry.id)
        guard let result = entries.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.invalidResponse }
        return result.pageURL
    }

    func delete(_ entry: WorkoutPageEntry) async throws {
        try beginOperation()
        defer { isWorking = false }
        guard let page = registry.pages.first(where: { $0.id == entry.id }) else { return }
        let root = try ownerRoot(for: page)
        var state = try localState(page, root: root)
        // Never finish a pending upload just to delete it. The server must acknowledge
        // an owner-bound cancellation even if an earlier create has not published yet.
        state.pending = Pending(kind: .delete, body: nil, workout: nil, newViewKey: nil, newViewKeyRecovery: nil)
        try storeState(state, page: page, root: root)
        try await finishPending(pageID: page.id)
    }

    func rotateLink(_ entry: WorkoutPageEntry) async throws -> URL {
        try beginOperation()
        defer { isWorking = false }
        if let pendingPage = registry.pages.first(where: { $0.id == entry.id }),
           try localState(pendingPage, root: ownerRoot(for: pendingPage)).pending?.kind == .rotate {
            // Retrying a lost response must complete the existing replacement,
            // rather than immediately generating a second replacement link.
            try await finishPending(pageID: entry.id)
            guard let recovered = entries.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.invalidResponse }
            return recovered.pageURL
        }
        try await finishPending(pageID: entry.id)
        guard let page = registry.pages.first(where: { $0.id == entry.id }) else { throw WorkoutPageError.missingPage }
        let root = try ownerRoot(for: page)
        var state = try localState(page, root: root)
        let viewKey = try WorkoutPageCrypto.randomSecret()
        let envelope = try recoveryEnvelope(viewKey: viewKey, localWorkoutID: state.localWorkoutID, root: root, pageID: page.id)
        let body = try WorkoutPageExport.encoder().encode(RotateBody(expectedVersion: page.version, viewKey: viewKey, viewKeyRecovery: envelope))
        state.pending = Pending(kind: .rotate, body: body, workout: nil, newViewKey: viewKey, newViewKeyRecovery: envelope)
        try storeState(state, page: page, root: root)
        try await finishPending(pageID: page.id)
        guard let result = entries.first(where: { $0.id == page.id }) else { throw WorkoutPageError.invalidResponse }
        return result.pageURL
    }

    func refresh() async throws {
        try beginOperation()
        defer { isWorking = false }
        for root in vault.roots { try await refreshOwner(root) }
    }

    /// No server ever receives this code or the envelope-encryption key it derives.
    func exportRecoveryCode() throws -> String {
        try ensureReady()
        _ = try activeRoot()
        let code = RecoveryCode(version: 1, origin: origin, roots: vault.roots)
        return "BPM-PAGES-1." + WorkoutPageCrypto.base64URL(try WorkoutPageExport.encoder().encode(code))
    }

    func restoreRecoveryCode(_ text: String) async throws {
        try beginOperation()
        defer { isWorking = false }
        let prefix = "BPM-PAGES-1."
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.hasPrefix(prefix), compact.count <= 32_768,
              let data = WorkoutPageCrypto.decodeBase64URL(String(compact.dropFirst(prefix.count))),
              let code = try? JSONDecoder().decode(RecoveryCode.self, from: data),
              code.version == 1, code.origin == origin, !code.roots.isEmpty, code.roots.count <= 50 else {
            throw WorkoutPageError.invalidRecoveryCode
        }
        var next = vault
        for root in code.roots {
            _ = try WorkoutPageCrypto.ownerID(root: root)
            if !next.roots.contains(root) { next.roots.append(root) }
        }
        guard next.roots.count <= 50 else { throw WorkoutPageError.invalidRecoveryCode }
        // Merge, never replace, the old owners. Recovery remains durable if a read fails.
        try saveVault(next)
        for root in code.roots { try await refreshOwner(root) }
    }

    private var origin: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string!
    }

    private var vaultKey: String { "owners.\(WorkoutPageCrypto.digest(baseURL.absoluteString))" }

    private func beginOperation() throws {
        try ensureReady()
        guard !isWorking else { throw WorkoutPageError.busy }
        isWorking = true
        lastError = nil
    }

    private func ensureReady() throws {
        if let initializationError { throw initializationError }
        guard baseURL.scheme == "https" ||
                (baseURL.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(baseURL.host ?? "")),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw WorkoutPageError.unavailable
        }
    }

    private func activeRoot() throws -> String {
        if let root = vault.roots.first { return root }
        let root = try WorkoutPageCrypto.randomSecret()
        try saveVault(Vault(roots: [root]))
        return root
    }

    private func saveVault(_ next: Vault) throws {
        try secureStore.set(try JSONEncoder().encode(next), for: vaultKey)
        vault = next
    }

    private func ownerRoot(for page: StoredPage) throws -> String {
        guard let root = try vault.roots.first(where: { try WorkoutPageCrypto.ownerID(root: $0) == page.ownerID }) else {
            throw WorkoutPageError.secureStorage
        }
        return root
    }

    private func localState(_ page: StoredPage, root: String) throws -> LocalState {
        let data = try WorkoutPageCrypto.open(page.encryptedState, root: root, context: "local:\(page.id)")
        return try JSONDecoder().decode(LocalState.self, from: data)
    }

    private func sealState(_ state: LocalState, root: String, pageID: String) throws -> String {
        try WorkoutPageCrypto.seal(WorkoutPageExport.encoder().encode(state), root: root, context: "local:\(pageID)")
    }

    private func recoveryEnvelope(viewKey: String, localWorkoutID: UUID?, root: String, pageID: String) throws -> String {
        try WorkoutPageCrypto.seal(JSONEncoder().encode(RecoveryEnvelope(viewKey: viewKey, localWorkoutID: localWorkoutID)),
                                   root: root, context: "view:\(pageID)")
    }

    private func openRecoveryEnvelope(_ envelope: String, root: String, pageID: String) throws -> RecoveryEnvelope {
        guard envelope.count <= 2_048 else { throw WorkoutPageError.invalidResponse }
        let value = try JSONDecoder().decode(RecoveryEnvelope.self,
            from: WorkoutPageCrypto.open(envelope, root: root, context: "view:\(pageID)"))
        guard WorkoutPageCrypto.decodeBase64URL(value.viewKey)?.count == 32 else { throw WorkoutPageError.invalidResponse }
        return value
    }

    private func fingerprint(_ workout: WorkoutPageExport) throws -> String { WorkoutPageCrypto.digest(try workout.encoded()) }

    private func stageUpdate(page: StoredPage, root: String, state: LocalState, workout: WorkoutPageExport, staged: Bool = false) throws {
        let body = try WorkoutPageExport.encoder().encode(UpdateBody(expectedVersion: page.version, workout: workout, staged: staged ? true : nil))
        _ = try WorkoutPageCompression.gzip(body)
        var next = state
        next.pending = Pending(kind: .update, body: body, workout: workout, newViewKey: nil, newViewKeyRecovery: nil, staged: staged ? true : nil)
        try storeState(next, page: page, root: root)
    }

    private func storeState(_ state: LocalState, page: StoredPage, root: String) throws {
        var next = registry
        guard let index = next.pages.firstIndex(where: { $0.id == page.id }) else { throw WorkoutPageError.missingPage }
        next.pages[index].encryptedState = try sealState(state, root: root, pageID: page.id)
        try persist(next)
    }

    private func finishPending(pageID: String, activate: Bool = true, retryExpiredStage: Bool = true) async throws {
        guard let page = registry.pages.first(where: { $0.id == pageID }) else { throw WorkoutPageError.missingPage }
        let root = try ownerRoot(for: page)
        var state = try localState(page, root: root)
        guard let pending = state.pending else { return }
        let ownerKey = try WorkoutPageCrypto.ownerKey(root: root)
        // A background retry must never publish an older pending operation.
        if !activate, pending.staged != true { return }
        if !activate, pending.stageID != nil { return }
        let isActivation = pending.stageID != nil
        var path: String
        var method: String
        switch pending.kind {
        case .create: path = "api/workout-pages"; method = "POST"
        case .update: path = "api/workout-pages/\(page.id)"; method = "PUT"
        case .rotate: path = "api/workout-pages/\(page.id)/rotate"; method = "POST"
        case .delete: path = "api/workout-pages/\(page.id)"; method = "DELETE"
        }
        if isActivation {
            path = "api/workout-pages/\(page.id)/activate"
            method = "POST"
        }
        var request = makeRequest(path: path, method: method, credential: ownerKey)
        if let stageID = pending.stageID {
            request.httpBody = try JSONEncoder().encode(["stageID": stageID])
        } else if let body = pending.body {
            request.httpBody = try WorkoutPageCompression.gzip(body)
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        let response: Data
        do {
            response = try await send(request, ownerKey: ownerKey, attested: !isActivation && (pending.kind == .create || pending.kind == .update))
        } catch {
            if isActivation, retryExpiredStage,
               case WorkoutPageError.server(_, let code) = error,
               ["STAGE_EXPIRED", "STAGE_CONFLICT"].contains(code) {
                state.pending?.stageID = nil
                try storeState(state, page: page, root: root)
                try await finishPending(pageID: pageID, activate: activate, retryExpiredStage: false)
                return
            }
            // An update/rotation may have completed before its response disappeared.
            // Reconcile a version conflict against the authoritative registry instead
            // of replacing a newer version or minting a duplicate page.
            if case WorkoutPageError.server(_, let code) = error,
               ["VERSION_CONFLICT", "PAGE_CONFLICT", "WORKOUT_PAGE_CONFLICT", "CONFLICT"].contains(code),
               pending.kind != .delete {
                try await refreshOwner(root)
                if let reconciled = registry.pages.first(where: { $0.id == pageID }),
                   try localState(reconciled, root: root).pending == nil {
                    let recovered = try localState(reconciled, root: root)
                    if let workout = pending.workout, try recovered.fingerprint == fingerprint(workout) { return }
                    if pending.kind == .rotate, recovered.viewKey == pending.newViewKey { return }
                }
            }
            throw error
        }

        if pending.kind == .delete {
            struct DeletionAcknowledgment: Decodable { let success: Bool }
            guard (try? JSONDecoder().decode(DeletionAcknowledgment.self, from: response))?.success == true else {
                throw WorkoutPageError.invalidResponse
            }
            var next = registry
            next.pages.removeAll { $0.id == pageID }
            try persist(next)
            return
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: response)
        guard metadata.pageID == pageID, metadata.version > 0,
              let created = MeasurementDateCoding.date(from: metadata.createdAt),
              let updated = MeasurementDateCoding.date(from: metadata.updatedAt) else { throw WorkoutPageError.invalidResponse }
        let recovered = try openRecoveryEnvelope(metadata.viewKeyRecovery, root: root, pageID: pageID)
        let expectedViewKey = pending.newViewKey ?? state.viewKey
        guard recovered.viewKey == expectedViewKey else { throw WorkoutPageError.invalidResponse }
        if let code = metadata.linkCode,
           code != (try WorkoutPageCrypto.linkCode(viewKey: expectedViewKey, pageID: pageID)) {
            throw WorkoutPageError.invalidResponse
        }
        if let stageID = metadata.stageID {
            guard pending.staged == true, !isActivation,
                  UUID(uuidString: stageID) != nil else { throw WorkoutPageError.invalidResponse }
            state.pending?.stageID = stageID
            try storeState(state, page: page, root: root)
            if activate { try await finishPending(pageID: pageID, retryExpiredStage: retryExpiredStage) }
            return
        }
        if let workout = pending.workout {
            state.title = workout.title
            state.description = workout.description ?? ""
            state.includeDate = workout.recordedAt != nil
            state.workoutDate = workout.workoutDate
            state.fingerprint = try fingerprint(workout)
        }
        state.viewKey = expectedViewKey
        state.pending = nil
        var next = registry
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw WorkoutPageError.missingPage }
        next.pages[index].status = .published
        next.pages[index].version = metadata.version
        next.pages[index].createdAt = created
        next.pages[index].updatedAt = updated
        next.pages[index].viewKeyRecovery = metadata.viewKeyRecovery
        next.pages[index].usesShortLink = metadata.linkCode != nil
        next.pages[index].encryptedState = try sealState(state, root: root, pageID: pageID)
        try persist(next)
    }

    private func send(_ request: URLRequest, ownerKey: String, attested: Bool) async throws -> Data {
        guard attested else { return try await WorkoutPageHTTP.checked(request, transport: transport) }
        do {
            let signed = try await attester.authorize(request, ownerKey: ownerKey)
            return try await WorkoutPageHTTP.checked(signed, transport: transport)
        } catch WorkoutPageError.server(_, let code) where ["ATTEST_KEY_UNKNOWN", "ATTESTATION_INVALID"].contains(code) {
            try attester.invalidate(ownerKey: ownerKey)
            let signed = try await attester.authorize(request, ownerKey: ownerKey)
            return try await WorkoutPageHTTP.checked(signed, transport: transport)
        } catch WorkoutPageError.server(_, let code) where ["ATTEST_CHALLENGE_EXPIRED", "ATTEST_ASSERTION_INVALID"].contains(code) {
            let signed = try await attester.authorize(request, ownerKey: ownerKey)
            return try await WorkoutPageHTTP.checked(signed, transport: transport)
        }
    }

    private func refreshOwner(_ root: String) async throws {
        let ownerID = try WorkoutPageCrypto.ownerID(root: root)
        let ownerKey = try WorkoutPageCrypto.ownerKey(root: root)
        var all: [Metadata] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var request = makeRequest(path: "api/workout-pages", method: "GET", credential: ownerKey)
            if let cursor {
                var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                request.url = components.url
            }
            let data = try await WorkoutPageHTTP.checked(request, transport: transport)
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            all += listing.pages
            guard all.count <= 50_000 else { throw WorkoutPageError.invalidResponse }
            cursor = listing.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw WorkoutPageError.invalidResponse }
        } while cursor != nil

        var next = registry
        let remoteIDs = Set(all.map(\.pageID))
        next.pages.removeAll { $0.ownerID == ownerID && $0.status == .published && !remoteIDs.contains($0.id) }
        // Listing is complete, so absence is now authoritative. Recovery progress is
        // committed per page below; one failed read cannot discard an entire archive.
        try persist(next)
        var foundConflict = false
        for metadata in all {
            guard UUID(uuidString: metadata.pageID)?.uuidString.lowercased() == metadata.pageID,
                  metadata.version > 0,
                  let created = MeasurementDateCoding.date(from: metadata.createdAt),
                  let updated = MeasurementDateCoding.date(from: metadata.updatedAt) else { throw WorkoutPageError.invalidResponse }
            let recovery = try openRecoveryEnvelope(metadata.viewKeyRecovery, root: root, pageID: metadata.pageID)
            if let code = metadata.linkCode,
               code != (try WorkoutPageCrypto.linkCode(viewKey: recovery.viewKey, pageID: metadata.pageID)) {
                throw WorkoutPageError.invalidResponse
            }
            let existing = next.pages.first { $0.id == metadata.pageID && $0.ownerID == ownerID }
            if let existing, existing.version == metadata.version, existing.viewKeyRecovery == metadata.viewKeyRecovery {
                // A read-only refresh must not discard an action the server has not
                // applied, especially a pending deletion or failed content update.
                if existing.usesShortLink != (metadata.linkCode != nil),
                   let index = next.pages.firstIndex(where: { $0.id == existing.id }) {
                    next.pages[index].usesShortLink = metadata.linkCode != nil
                    try persist(next)
                }
                continue
            }
            let workout = try await fetchWorkout(pageID: metadata.pageID, viewKey: recovery.viewKey)
            let remoteFingerprint = try fingerprint(workout)
            var preservedPending: Pending?
            if let existing, let pending = try localState(existing, root: root).pending {
                if pending.kind == .delete { preservedPending = pending }
                else if let intended = pending.workout, try fingerprint(intended) != remoteFingerprint { foundConflict = true }
                else if pending.kind == .rotate, pending.newViewKey != recovery.viewKey { foundConflict = true }
            }
            let state = LocalState(viewKey: recovery.viewKey, localWorkoutID: recovery.localWorkoutID,
                                   title: workout.title, description: workout.description ?? "", includeDate: workout.recordedAt != nil,
                                   workoutDate: workout.workoutDate,
                                   fingerprint: remoteFingerprint, pending: preservedPending)
            let restored = StoredPage(id: metadata.pageID, ownerID: ownerID, version: metadata.version,
                                      createdAt: created, updatedAt: updated, status: .published,
                                      viewKeyRecovery: metadata.viewKeyRecovery,
                                      encryptedState: try sealState(state, root: root, pageID: metadata.pageID), usesShortLink: metadata.linkCode != nil)
            if let index = next.pages.firstIndex(where: { $0.id == metadata.pageID }) { next.pages[index] = restored }
            else { next.pages.append(restored) }
            try persist(next)
        }
        if foundConflict {
            throw WorkoutPageError.server("This page changed on another device. Its latest version is now shown. Review it before updating again.", code: "PAGE_CONFLICT")
        }
    }

    private func fetchWorkout(pageID: String, viewKey: String) async throws -> WorkoutPageExport {
        let request = makeRequest(path: "api/workout-pages/\(pageID)", method: "GET", credential: viewKey)
        let data = try await WorkoutPageHTTP.checked(request, transport: transport)
        let workout = try JSONDecoder().decode(WorkoutPageExport.self, from: data)
        guard workout.schemaVersion == 1, workout.calculationVersion == 1 else { throw WorkoutPageError.invalidResponse }
        return workout
    }

    private func makeRequest(path: String, method: String, credential: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func persist(_ next: Registry) throws {
        do {
            try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(next)
            try data.write(to: registryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw WorkoutPageError.localStorage }
        registry = next
        try publishEntries()
    }

    private func publishEntries() throws {
        var result: [WorkoutPageEntry] = []
        for page in registry.pages {
            // The encrypted registry may survive a reinstall when this-device-only
            // Keychain items do not. Keep locked records intact for recovery import.
            guard let root = try vault.roots.first(where: { try WorkoutPageCrypto.ownerID(root: $0) == page.ownerID }) else { continue }
            let state = try localState(page, root: root)
            let pathID = page.usesShortLink == true ? try WorkoutPageCrypto.linkCode(viewKey: state.viewKey, pageID: page.id) : page.id
            var components = URLComponents(url: baseURL.appendingPathComponent("w/\(pathID)"), resolvingAgainstBaseURL: false)!
            if page.usesShortLink != true {
                components.queryItems = [URLQueryItem(name: "p", value: try WorkoutPageCrypto.previewToken(viewKey: state.viewKey, pageID: page.id))]
            }
            components.fragment = state.viewKey
            guard let url = components.url else { throw WorkoutPageError.invalidResponse }
            result.append(WorkoutPageEntry(id: page.id, pageURL: url, title: state.title, description: state.description,
                                          includeDate: state.includeDate, workoutDate: state.workoutDate, localWorkoutID: state.localWorkoutID,
                                          createdAt: page.createdAt, updatedAt: page.updatedAt, status: page.status, version: page.version,
                                          hasPendingDeletion: state.pending?.kind == .delete))
        }
        entries = result.sorted { $0.createdAt > $1.createdAt }
    }

    private static func defaultRegistryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("BPM/shared-workout-pages-v1.json")
    }
}
