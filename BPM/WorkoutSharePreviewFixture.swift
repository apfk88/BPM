#if DEBUG
import SwiftUI
import zlib

/// Synthetic data used only by previews and the explicit UI-test launch argument.
enum WorkoutSharePreviewFixture {
    static let record = makeRecord()
    static let noHeartRateRecord = makeRecord(includesHeartRate: false)

    private static func makeRecord(includesHeartRate: Bool = true) -> WorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_793_030_400)
        let duration = 2_520.0
        let config = HeartRateZoneConfig(maxHeartRate: 190)
        let samples: [WorkoutHeartRateSample] = includesHeartRate ? stride(from: 0.0, through: duration, by: 1).map { time in
            let base: Double
            if time < 300 { base = 88 + time / 300 * 48 }
            else if time > 2220 { base = 137 - (time - 2220) / 300 * 42 }
            else { base = 143 + 17 * sin(time / 90) + 5 * sin(time / 19) }
            return WorkoutHeartRateSample(timestamp: start.addingTimeInterval(time),
                                          bpm: Int(base + 2 * sin(time / 3)), workoutTime: time)
        } : []
        // Each sample covers the following second; the last sample is the endpoint.
        let zoneDurations = samples.dropLast().reduce(into: [HeartRateZone: TimeInterval]()) { result, sample in
            if let zone = HeartRateZone.zone(for: sample.bpm, config: config) {
                result[zone, default: 0] += 1
            }
        }
        let zones = HeartRateZone.allCases.compactMap { zone -> WorkoutZoneSummary? in
            guard let duration = zoneDurations[zone], duration > 0 else { return nil }
            return WorkoutZoneSummary(id: UUID(), zone: zone.rawValue, duration: duration)
        }
        func set(_ label: String, from lower: TimeInterval, to upper: TimeInterval,
                 rest: Bool = false, cooldown: Bool = false, workNumber: Int? = nil) -> WorkoutSetSummary {
            let values = samples.filter {
                let time = $0.workoutTime ?? 0
                return time >= lower && time < upper
            }.map(\.bpm)
            let average = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            return WorkoutSetSummary(id: UUID(), label: label, setTime: upper - lower, totalTime: upper,
                                     isRestSet: rest, isCooldownSet: cooldown,
                                     associatedWorkSetNumber: workNumber,
                                     avgBpm: average, minBpm: values.min(), maxBpm: values.max())
        }
        let sets = [
            set("Warm-up", from: 0, to: 300),
            set("1", from: 300, to: 900),
            set("1R", from: 900, to: 1020, rest: true, workNumber: 1),
            set("2", from: 1020, to: 1620),
            set("2R", from: 1620, to: 1740, rest: true, workNumber: 2),
            set("3", from: 1740, to: 2220),
            set("Cooldown", from: 2220, to: duration, rest: true, cooldown: true)
        ]
        return WorkoutRecord(id: UUID(), schemaVersion: WorkoutRecord.schemaVersion,
            title: "Morning intervals", startAt: start, endAt: start.addingTimeInterval(duration),
            durationSeconds: duration, avgHr: includesHeartRate ? 135 : nil,
            maxHr: includesHeartRate ? 167 : nil, minHr: includesHeartRate ? 88 : nil,
            hrv: nil, hrr: includesHeartRate ? 28 : nil,
            caloriesTotal: includesHeartRate ? 418 : nil, caloriesActive: includesHeartRate ? 362 : nil,
            hrSamples: samples, zones: zones, sets: sets,
            notes: "Synthetic workout for share-card previews.", source: "preview", appVersion: "preview",
            healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
            createdAt: start, updatedAt: start, zoneConfig: config)
    }
}

struct WorkoutSharePreviewScene: View {
    @StateObject private var store: WorkoutStore
    @StateObject private var pageService: WorkoutPageService
    @State private var pageFixtureReady: Bool
    @State private var pageFixtureError: String?
    private let record: WorkoutRecord
    private let pageMode: String?
    private let pageBackend: WorkoutSharePreviewPages

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutSharePreview-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "BPMSharePreview")!
        defaults.set(36_500, forKey: WorkoutDefaultsKey.retentionDays)
        let store = WorkoutStore(storeURL: root.appendingPathComponent("workouts.json"), userDefaults: defaults,
                                 iCloudStore: WorkoutSharePreviewCloud())
        let arguments = ProcessInfo.processInfo.arguments
        let record = arguments.contains("--workout-history-no-heart-rate")
            ? WorkoutSharePreviewFixture.noHeartRateRecord : WorkoutSharePreviewFixture.record
        if !arguments.contains("--workout-history-empty") {
            store.saveWorkout(record)
        }
        self.record = record
        pageMode = ["published", "pending", "deletion-pending"].first {
            arguments.contains("--workout-shared-page-\($0)")
        }
        let backend = WorkoutSharePreviewPages()
        pageBackend = backend
        let pages = WorkoutPageService(baseURL: URL(string: "https://bpm.example")!,
                                       registryURL: root.appendingPathComponent("pages.json"),
                                       secureStore: WorkoutSharePreviewSecrets(),
                                       transport: { try await backend.send($0) },
                                       attester: WorkoutSharePreviewAttester())
        _store = StateObject(wrappedValue: store)
        _pageService = StateObject(wrappedValue: pages)
        _pageFixtureReady = State(initialValue: pageMode == nil)
    }

    var body: some View {
        NavigationStack {
            if pageFixtureReady {
                WorkoutHistoryView(store: store, pageService: pageService)
            } else if let pageFixtureError {
                Text(pageFixtureError)
            } else {
                ProgressView("Preparing synthetic workout")
            }
        }
        .task {
            guard !pageFixtureReady, pageFixtureError == nil else { return }
            do {
                let title = WorkoutShareSnapshot(record: record).title
                if pageMode == "pending" {
                    try await pageService.stageShare(record: record, title: title,
                                                     description: record.notes ?? "", includeDate: false)
                } else {
                    _ = try await pageService.prepareShare(record: record, title: title,
                                                           description: record.notes ?? "", includeDate: false)
                    if pageMode == "deletion-pending", let entry = pageService.entries.first {
                        pageBackend.failNextDeletion = true
                        do { try await pageService.delete(entry) } catch { }
                    }
                }
                pageFixtureReady = true
            } catch { pageFixtureError = error.localizedDescription }
        }
    }
}

private final class WorkoutSharePreviewSecrets: WorkoutPageSecureStoring {
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) throws { values[key] = data }
}

@MainActor
private struct WorkoutSharePreviewAttester: WorkoutPageAttesting {
    func authorize(_ request: URLRequest, ownerKey: String) async throws -> URLRequest { request }
    func invalidate(ownerKey: String) throws { }
}

/// Local-only transport for the explicit UI fixture. No request leaves the app.
@MainActor
private final class WorkoutSharePreviewPages {
    private struct Page {
        let id: String
        let owner: String
        var viewKey: String
        var recovery: String
        var workout: [String: Any]
        var version: Int
        var metadata: [String: Any] {
            ["pageID": id, "version": version, "createdAt": "2026-11-11T00:00:00.000Z",
             "updatedAt": "2026-11-11T00:00:00.000Z", "viewKeyRecovery": recovery,
             "linkCode": try! WorkoutPageCrypto.linkCode(viewKey: viewKey, pageID: id)]
        }
    }
    private var pages: [String: Page] = [:]
    private var drafts: [String: (id: String, page: Page)] = [:]
    var failNextDeletion = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw WorkoutPageError.invalidResponse }
        let path = String(url.path.dropFirst("/api/workout-pages".count))
        let parts = path.split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        let key = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        let body: [String: Any]
        if let data = request.httpBody {
            let json = request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" ? try ungzip(data) : data
            guard let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw WorkoutPageError.invalidResponse
            }
            body = decoded
        } else { body = [:] }
        func response(_ object: Any, status: Int = 200) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object),
             HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func missing() throws -> (Data, HTTPURLResponse) {
            try response(["message": "Synthetic page is unavailable", "code": "PAGE_NOT_FOUND"], status: 404)
        }

        if parts.isEmpty, method == "GET" {
            return try response(["pages": pages.values.filter { $0.owner == key }.map(\.metadata), "nextCursor": NSNull()])
        }
        if parts.isEmpty, method == "POST" {
            guard let id = body["pageID"] as? String, let view = body["viewKey"] as? String,
                  let recovery = body["viewKeyRecovery"] as? String, let workout = body["workout"] as? [String: Any] else {
                throw WorkoutPageError.invalidResponse
            }
            let page = Page(id: id, owner: key, viewKey: view, recovery: recovery, workout: workout, version: 1)
            if body["staged"] as? Bool == true {
                let draft = (id: UUID().uuidString.lowercased(), page: page)
                drafts[id] = draft
                return try response(page.metadata.merging(["stageID": draft.id, "staged": true,
                                                           "stageExpiresAt": "2099-11-12T00:00:00.000Z"]) { _, new in new })
            }
            pages[id] = page
            return try response(page.metadata)
        }
        guard let id = parts.first else { return try missing() }
        if parts.last == "activate", method == "POST", let draft = drafts[id],
           draft.page.owner == key, draft.id == body["stageID"] as? String {
            pages[id] = draft.page
            drafts.removeValue(forKey: id)
            return try response(draft.page.metadata)
        }
        if method == "DELETE", (pages[id]?.owner ?? drafts[id]?.page.owner) == key {
            if failNextDeletion {
                failNextDeletion = false
                throw URLError(.notConnectedToInternet)
            }
            pages.removeValue(forKey: id)
            drafts.removeValue(forKey: id)
            return try response(["success": true])
        }
        guard var page = pages[id] else { return try missing() }
        if method == "GET", page.viewKey == key { return try response(page.workout) }
        guard page.owner == key else { return try missing() }
        if method == "PUT", let workout = body["workout"] as? [String: Any] {
            page.workout = workout
            page.version += 1
            pages[id] = page
            return try response(page.metadata)
        }
        if parts.last == "rotate", method == "POST", let view = body["viewKey"] as? String,
           let recovery = body["viewKeyRecovery"] as? String {
            page.viewKey = view
            page.recovery = recovery
            page.version += 1
            pages[id] = page
            return try response(page.metadata)
        }
        return try missing()
    }

    private func ungzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WorkoutPageError.invalidResponse
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            var status = Z_OK
            repeat {
                let count = buffer.count
                status = buffer.withUnsafeMutableBufferPointer { bytes in
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw WorkoutPageError.invalidResponse }
                output.append(buffer, count: count - Int(stream.avail_out))
                guard output.count <= WorkoutPageExport.maximumDecodedBytes else { throw WorkoutPageError.tooLarge }
            } while status != Z_STREAM_END
            return output
        }
    }
}

final class WorkoutSharePreviewCloud: ICloudKeyValueStore {
    func synchronize() -> Bool { true }
    func object(forKey aKey: String) -> Any? { nil }
    func string(forKey aKey: String) -> String? { nil }
    func bool(forKey aKey: String) -> Bool { false }
    func data(forKey aKey: String) -> Data? { nil }
    func set(_ anObject: Any?, forKey aKey: String) { }
    func removeObject(forKey aKey: String) { }
}

#Preview("Workout share card") {
    @Previewable @State var accent: WorkoutShareAccent = .white
    WorkoutShareCardEditor(record: WorkoutSharePreviewFixture.record, style: .chart, source: .workoutDetail,
                           accent: $accent)
        .preferredColorScheme(.dark)
}
#endif
