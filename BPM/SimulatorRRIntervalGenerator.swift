import Foundation

/// Synthetic beat timing for the simulator only. Packet frequency does not set beat count.
struct SimulatorRRIntervalGenerator {
    private var lastPacketTicks: TimeInterval?
    private var lastBeatTicks: TimeInterval = 0
    private var nextInterval: TimeInterval = 0

    mutating func intervals(
        at ticks: TimeInterval,
        heartRate: Int,
        variation: () -> Double = { Double.random(in: -0.05...0.05) }
    ) -> [Double] {
        guard ticks.isFinite, (40...220).contains(heartRate) else { return [] }
        let baseInterval = 60.0 / Double(heartRate)
        guard let previousPacket = lastPacketTicks,
              ticks >= previousPacket, ticks - previousPacket <= 5 else {
            // A new connection or an interrupted simulator timer starts a fresh
            // beat schedule. Do not invent a backlog of missed measurements.
            lastPacketTicks = ticks
            lastBeatTicks = ticks
            nextInterval = baseInterval * (1 + min(0.05, max(-0.05, variation())))
            return []
        }
        lastPacketTicks = ticks
        var values: [Double] = []
        while lastBeatTicks + nextInterval <= ticks {
            lastBeatTicks += nextInterval
            values.append(nextInterval * 1000)
            nextInterval = baseInterval * (1 + min(0.05, max(-0.05, variation())))
        }
        return values
    }
}
