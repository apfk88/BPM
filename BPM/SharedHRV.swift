import Foundation

/// Original BLE beat intervals. Values and packet receipt ticks are never
/// reconstructed from BPM or shifted according to network arrival jitter.
struct SharedRRInterval: Codable, Equatable {
    let id: UUID
    let value: Double
    let receivedTicks: TimeInterval
}

struct SharedRRStreamSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var sequence: Int64 = 0
    let streamID: UUID
    let supportsRRIntervals: Bool
    let sourceTicks: TimeInterval
    let intervals: [SharedRRInterval]

    static func capture(
        from monitor: HeartRateBluetoothManager,
        sequence: Int64 = 0,
        sourceTicks: TimeInterval = MeasurementClock.ticks
    ) -> SharedRRStreamSnapshot {
        let supported = monitor.hasActiveDataSource && monitor.supportsRRIntervals && monitor.freshHeartRate != nil
        let intervals = supported ? monitor.rrIntervals.filter {
            $0.receivedTicks <= sourceTicks && sourceTicks - $0.receivedTicks <= 15
        }.suffix(128).map {
            SharedRRInterval(id: $0.id, value: $0.value, receivedTicks: $0.receivedTicks)
        } : []
        return SharedRRStreamSnapshot(sequence: sequence, streamID: monitor.rrStreamID,
                                      supportsRRIntervals: supported, sourceTicks: sourceTicks, intervals: intervals)
    }
}

/// Keeps one original source clock and stream throughout a remote measurement.
/// The receiver's monotonic clock is used only to expire stale transport/data.
final class SharedRRStreamBuffer {
    private(set) var intervals: [RRInterval] = []
    private(set) var streamID: UUID?
    private(set) var sourceTicks: TimeInterval?
    private var sequence: Int64?
    private var knownIntervals: [UUID: SharedRRInterval] = [:]
    private var latestIntervalID: UUID?
    private var packetExpiresAt: TimeInterval?
    private var beatExpiresAt: TimeInterval?
    private var supportsIntervals = false

    @discardableResult
    func receive(
        snapshot: SharedRRStreamSnapshot,
        serverTimestamp: Int64,
        serverTime: Int64,
        receivedAtTicks: TimeInterval,
        transportAge: TimeInterval,
        now: Date
    ) -> Bool {
        guard sequence == nil || snapshot.sequence > sequence! else { return false }
        sequence = snapshot.sequence
        let sourceAge = (Double(serverTime) - Double(serverTimestamp)) / 1000 + transportAge
        guard snapshot.schemaVersion == 1, snapshot.sequence >= 0,
              snapshot.sourceTicks.isFinite, snapshot.sourceTicks >= 0,
              receivedAtTicks.isFinite, receivedAtTicks >= 0, transportAge.isFinite, transportAge >= 0,
              serverTimestamp <= serverTime, sourceAge >= 0, sourceAge < 5,
              snapshot.intervals.count <= 128,
              snapshot.supportsRRIntervals || snapshot.intervals.isEmpty,
              Set(snapshot.intervals.map(\.id)).count == snapshot.intervals.count,
              snapshot.intervals.allSatisfy({
                  $0.value.isFinite && (0...64_000).contains($0.value)
                      && $0.receivedTicks.isFinite && $0.receivedTicks >= 0
                      && $0.receivedTicks <= snapshot.sourceTicks
                      && snapshot.sourceTicks - $0.receivedTicks <= 15
              }),
              zip(snapshot.intervals, snapshot.intervals.dropFirst()).allSatisfy({ $0.receivedTicks <= $1.receivedTicks }) else {
            clearStream()
            return false
        }

        if streamID != snapshot.streamID {
            clearStream()
            streamID = snapshot.streamID
        } else if let sourceTicks, snapshot.sourceTicks < sourceTicks {
            clearStream()
            return false
        }
        sourceTicks = snapshot.sourceTicks
        supportsIntervals = snapshot.supportsRRIntervals
        packetExpiresAt = receivedAtTicks + 5 - sourceAge
        guard supportsIntervals else {
            intervals.removeAll()
            knownIntervals.removeAll()
            latestIntervalID = nil
            beatExpiresAt = nil
            return true
        }

        for interval in snapshot.intervals {
            if let existing = knownIntervals[interval.id] {
                guard existing == interval else {
                    clearStream()
                    return false
                }
                continue
            }
            guard interval.receivedTicks >= (intervals.last?.receivedTicks ?? 0) else {
                clearStream()
                return false
            }
            knownIntervals[interval.id] = interval
            intervals.append(RRInterval(
                value: interval.value,
                timestamp: now.addingTimeInterval(interval.receivedTicks - snapshot.sourceTicks - sourceAge),
                receivedTicks: interval.receivedTicks
            ))
        }

        if let latest = snapshot.intervals.last, latest.id != latestIntervalID {
            latestIntervalID = latest.id
            let beatAge = snapshot.sourceTicks - latest.receivedTicks + sourceAge
            beatExpiresAt = receivedAtTicks + max(0, 5 - beatAge)
        }
        // Repeated uploads of the same last beat cannot renew its freshness.
        let cutoff = snapshot.sourceTicks - 180
        intervals.removeAll { $0.receivedTicks < cutoff }
        knownIntervals = knownIntervals.filter { $0.value.receivedTicks >= cutoff }
        return true
    }

    func isFresh(at ticks: TimeInterval) -> Bool {
        guard supportsIntervals, streamID != nil, sourceTicks != nil,
              let packetExpiresAt, let beatExpiresAt, ticks.isFinite, ticks >= 0 else { return false }
        return ticks < packetExpiresAt && ticks < beatExpiresAt
    }

    func reset() {
        sequence = nil
        clearStream()
    }

    private func clearStream() {
        intervals.removeAll()
        knownIntervals.removeAll()
        streamID = nil
        sourceTicks = nil
        latestIntervalID = nil
        packetExpiresAt = nil
        beatExpiresAt = nil
        supportsIntervals = false
    }
}
