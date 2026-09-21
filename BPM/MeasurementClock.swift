import Foundation
import Darwin

/// Elapsed time includes device sleep and is independent of calendar-clock changes.
final class MeasurementClock {
    private let anchorDate: Date
    private let anchorTicks: TimeInterval

    init(anchorDate: Date = Date(), anchorTicks: TimeInterval = MeasurementClock.ticks) {
        self.anchorDate = anchorDate
        self.anchorTicks = anchorTicks
    }

    func now() -> Date {
        anchorDate.addingTimeInterval(Self.ticks - anchorTicks)
    }

    static var ticks: TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static var bootSessionID: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
