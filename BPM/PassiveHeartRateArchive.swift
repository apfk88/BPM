import Foundation
import SQLite3
import OSLog

struct PassiveHeartRateSession: Identifiable {
    let id: UUID
    let startAt: Date
    let endAt: Date
    let sampleCount: Int
}

/// Local history of measurements received from a strap while the workout timer is idle.
/// All reads and writes share a queue so a history query sees every preceding receipt.
final class PassiveHeartRateArchive: @unchecked Sendable {
    static let shared = PassiveHeartRateArchive()
    static let retentionDays = 7
    static let sessionGap: TimeInterval = 60

    private let databaseURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "bpm.passive-heart-rate", qos: .utility)
    private let logger = Logger(subsystem: "kvamme.BPM", category: "HeartRateHistory")
    private var database: OpaquePointer?
    private var lastPrunedAt: Date?
    private var lastReceipt: (streamID: UUID, sessionID: UUID, timestamp: Date, rowID: Int64)?

    init(databaseURL: URL = PassiveHeartRateArchive.defaultDatabaseURL, now: @escaping () -> Date = Date.init) {
        self.databaseURL = databaseURL
        self.now = now
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    private static var defaultDatabaseURL: URL {
        #if DEBUG && targetEnvironment(simulator)
        if let directory = RetrospectiveWorkoutUITestFixture.directory {
            return directory.appendingPathComponent("history.sqlite")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BPM/PassiveHeartRate", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    func append(_ sample: HeartRateSample, streamID: UUID) {
        guard sample.value > 0, sample.sensorContactStatus != .notDetected else { return }
        queue.async {
            do {
                let db = try self.openDatabase()
                try self.pruneIfDue(db)
                let sessionID: UUID
                if let last = self.lastReceipt, streamID == last.streamID,
                   sample.timestamp >= last.timestamp,
                   sample.timestamp.timeIntervalSince(last.timestamp) <= Self.sessionGap {
                    sessionID = last.sessionID
                } else {
                    sessionID = UUID()
                }
                try self.withStatement(db, "INSERT INTO samples (session, time, bpm, contact, invalidated) VALUES (?, ?, ?, ?, ?)") { statement in
                    self.bind(sessionID, to: statement)
                    sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSinceReferenceDate)
                    sqlite3_bind_int64(statement, 3, Int64(sample.value))
                    sqlite3_bind_int(statement, 4, sample.sensorContactStatus == .detected ? 1 : 0)
                    if let invalidated = sample.invalidatedAt {
                        sqlite3_bind_double(statement, 5, invalidated.timeIntervalSinceReferenceDate)
                    }
                    try self.finishWrite(statement)
                }
                self.lastReceipt = (streamID, sessionID, sample.timestamp, sqlite3_last_insert_rowid(db))
            } catch {
                self.logger.error("Could not store a passive heart-rate reading")
            }
        }
    }

    func invalidateLastReading(at date: Date, streamID: UUID) {
        queue.async {
            guard let last = self.lastReceipt, last.streamID == streamID else { return }
            do {
                let db = try self.openDatabase()
                try self.withStatement(db, "UPDATE samples SET invalidated = ? WHERE rowid = ? AND invalidated IS NULL") { statement in
                    sqlite3_bind_double(statement, 1, max(date, last.timestamp).timeIntervalSinceReferenceDate)
                    sqlite3_bind_int64(statement, 2, last.rowID)
                    try self.finishWrite(statement)
                }
            } catch {
                self.logger.error("Could not store a passive heart-rate signal boundary")
            }
        }
    }

    func pruneExpiredReadings() {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.databaseURL.path) else { return }
            do {
                try self.pruneIfDue(self.openDatabase())
            } catch {
                self.logger.error("Could not prune expired passive heart-rate readings")
            }
        }
    }

    func sessions() async throws -> [PassiveHeartRateSession] {
        try await read { db in
            try self.withStatement(db, """
                SELECT session, MIN(time), MAX(time), COUNT(*) FROM samples
                WHERE time >= ? GROUP BY session ORDER BY MAX(time) DESC
                """) { statement in
                sqlite3_bind_double(statement, 1, self.cutoff)
                var result: [PassiveHeartRateSession] = []
                while try self.nextRow(statement) {
                    guard let rawID = sqlite3_column_text(statement, 0),
                          let id = UUID(uuidString: String(cString: rawID)) else { throw ArchiveError.unavailable }
                    result.append(PassiveHeartRateSession(id: id, startAt: self.date(statement, 1),
                                                          endAt: self.date(statement, 2),
                                                          sampleCount: Int(sqlite3_column_int64(statement, 3))))
                }
                return result
            }
        }
    }

    func samples(for id: UUID) async throws -> [HeartRateSample] {
        try await read { db in
            try self.withStatement(db, """
                SELECT bpm, time, contact, invalidated FROM samples
                WHERE session = ? AND time >= ? ORDER BY time, rowid
                """) { statement in
                self.bind(id, to: statement)
                sqlite3_bind_double(statement, 2, self.cutoff)
                var values: [HeartRateSample] = []
                while try self.nextRow(statement) {
                    values.append(HeartRateSample(value: Int(sqlite3_column_int64(statement, 0)),
                                                  timestamp: self.date(statement, 1), workoutTime: nil,
                                                  sensorContactStatus: sqlite3_column_int(statement, 2) == 1 ? .detected : .unsupported,
                                                  invalidatedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : self.date(statement, 3)))
                }
                return values
            }
        }
    }

    private enum ArchiveError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Couldn’t access the saved heart-rate readings on this device." }
    }

    private func read<T>(_ block: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    let db = try self.openDatabase()
                    try self.pruneIfDue(db)
                    return try block(db)
                })
            }
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        var directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ArchiveError.unavailable
        }
        // WAL commits make each receipt durable across process termination. SQLite batches
        // checkpoints rather than synchronously flushing the flash storage on every packet.
        let schema = """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS samples (session TEXT NOT NULL, time REAL NOT NULL,
              bpm INTEGER NOT NULL, contact INTEGER NOT NULL, invalidated REAL);
            CREATE INDEX IF NOT EXISTS samples_session_time ON samples(session, time);
            CREATE INDEX IF NOT EXISTS samples_time ON samples(time);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ArchiveError.unavailable
        }
        database = handle
        return handle
    }

    private var cutoff: Double {
        now().addingTimeInterval(-Double(Self.retentionDays) * 86_400).timeIntervalSinceReferenceDate
    }

    private func pruneIfDue(_ db: OpaquePointer) throws {
        let current = now()
        if let lastPrunedAt, (0..<3600).contains(current.timeIntervalSince(lastPrunedAt)) { return }
        try withStatement(db, "DELETE FROM samples WHERE time < ?") { statement in
            sqlite3_bind_double(statement, 1, cutoff)
            try finishWrite(statement)
        }
        lastPrunedAt = current
    }

    private func withStatement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArchiveError.unavailable }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ id: UUID, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ArchiveError.unavailable
        }
    }

    private func finishWrite(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError.unavailable }
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }
}
