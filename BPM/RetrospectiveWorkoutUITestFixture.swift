#if DEBUG && targetEnvironment(simulator)
import Foundation

enum RetrospectiveWorkoutUITestFixture {
    static let directory: URL? = {
        guard let value = ProcessInfo.processInfo.environment["BPM_RECOVERY_TEST_ID"],
              let id = UUID(uuidString: value) else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutRecovery-\(id.uuidString)", isDirectory: true)
    }()

    static func seedIfRequested() {
        guard directory != nil,
              ProcessInfo.processInfo.arguments.contains("--seed-recovery-readings") else { return }
        let streamID = UUID()
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        for second in 0...180 {
            // Trimming the first minute removes a distinct peak from the saved chart.
            let reading = HeartRateSample(value: second < 60 ? 170 : 140,
                                          timestamp: start.addingTimeInterval(Double(second)),
                                          workoutTime: nil, sensorContactStatus: .detected)
            PassiveHeartRateArchive.shared.append(reading, streamID: streamID)
        }
    }
}
#endif
