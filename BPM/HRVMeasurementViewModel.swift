import Foundation
import Combine
import UIKit

enum HRVMeasurementState: Equatable {
    case idle
    case countingDown
    case completed
    case error(String)
}

final class HRVMeasurementViewModel: ObservableObject {
    @Published var state: HRVMeasurementState = .idle
    @Published var remainingTime: TimeInterval = 120
    @Published var hrvValue: Double?
    @Published var avgHeartRate: Int?
    @Published var minHeartRate: Int?
    @Published var maxHeartRate: Int?
    @Published var currentBPM: Int?
    @Published private(set) var isRemoteMeasurement = false

    private var timer: Timer?
    private var liveHeartRateTimer: Timer?
    private var heartRateCancellable: AnyCancellable?
    private var intervals: [RRInterval] = []
    private var seenIntervals: Set<UUID> = []
    private var heartRateSamples: [HRVHeartRateSample] = []
    private var heartRateSampleOffsets: [TimeInterval] = []
    private var seenHeartRateSamples: Set<UUID> = []
    private var startTime: Date?
    private var startTicks: TimeInterval?
    private var streamID: UUID?
    private var completedAt: Date?
    private let measurementDuration: TimeInterval = 120
    private let emitAnalytics: (AppAnalytics.Event, [String: String]) -> Void
    private let ticksProvider: () -> TimeInterval
    private let nowProvider: () -> Date
    private let playCompletionSound: () -> Void

    var currentHeartRate: (() -> Int?)?
    var getRRIntervals: (() -> [RRInterval])?
    var supportsRRIntervals: (() -> Bool)?
    var currentRRStreamID: (() -> UUID?)?
    /// Remote recordings use the original monitor's monotonic clock. Network
    /// receipt timing must not move raw beats into or out of the 120-second window.
    var measurementTicks: (() -> TimeInterval?)?
    var isRemoteSource: (() -> Bool)?

    init(
        ticksProvider: @escaping () -> TimeInterval = { MeasurementClock.ticks },
        nowProvider: @escaping () -> Date = Date.init,
        playCompletionSound: @escaping () -> Void = { AlertSoundPlayer.shared.playHRVComplete() },
        emitAnalytics: @escaping (AppAnalytics.Event, [String: String]) -> Void = AppAnalytics.signal
    ) {
        self.emitAnalytics = emitAnalytics
        self.ticksProvider = ticksProvider
        self.nowProvider = nowProvider
        self.playCompletionSound = playCompletionSound
    }

    var isCompleted: Bool { state == .completed }
    var canSaveMeasurement: Bool { isCompleted && !isRemoteMeasurement }
    var hasError: Bool { errorMessage != nil }
    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    func startMeasurement() {
        guard state != .countingDown else { return }
        reset()
        isRemoteMeasurement = isRemoteSource?() == true
        guard supportsRRIntervals?() == true, currentHeartRate?() != nil || isRemoteMeasurement,
              let currentStream = currentRRStreamID?(), let ticks = acquisitionTicks, ticks.isFinite else {
            let message = isRemoteMeasurement
                ? "HRV requires fresh raw beat intervals from the shared monitor. Check the monitor connection and keep sharing open."
                : "HRV requires fresh beat intervals from your connected heart rate monitor. Check your strap connection and contact, then try again."
            fail(reason: "sensor_unavailable", message)
            return
        }
        stopLiveHeartRateUpdates()
        startTime = nowProvider()
        startTicks = ticks
        streamID = currentStream
        // Identity, not array offsets: the manager's rolling history can be pruned.
        seenIntervals = Set((getRRIntervals?() ?? []).map(\.id))
        currentBPM = currentHeartRate?()
        state = .countingDown
        emitAnalytics(.hrvStart, [:])
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMeasurement() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Timer callbacks only refresh the display; monotonic time defines the window.
    func updateMeasurement() {
        guard state == .countingDown, let startTicks else { return }
        guard currentRRStreamID?() == streamID, supportsRRIntervals?() == true,
              (isRemoteSource?() == true) == isRemoteMeasurement,
              let nowTicks = acquisitionTicks, nowTicks.isFinite else {
            let message = isRemoteMeasurement
                ? "Shared beat data was interrupted or the monitor changed. Check the connection and measure again."
                : "The sensor connection or contact changed during measurement. Check your strap and measure again."
            fail(reason: "sensor_changed", message)
            return
        }
        let deadline = startTicks + measurementDuration
        for interval in getRRIntervals?() ?? [] where !seenIntervals.contains(interval.id) {
            seenIntervals.insert(interval.id)
            if interval.receivedTicks > startTicks && interval.receivedTicks <= deadline {
                intervals.append(interval)
            }
        }
        currentBPM = currentHeartRate?()
        remainingTime = max(0, deadline - nowTicks)
        if nowTicks >= deadline {
            completeMeasurement()
        } else if nowTicks - (intervals.last?.receivedTicks ?? startTicks) > 5 {
            fail(reason: "data_stopped", "Beat data stopped during measurement. Check your strap connection and measure again.")
        }
    }

    func observeHeartRate(from measurements: AnyPublisher<HeartRateSample, Never>) {
        heartRateCancellable = measurements.sink { [weak self] sample in
            self?.recordHeartRateSample(sample)
        }
    }

    /// Capture every received sensor value; UI timer polls are not measurements.
    func recordHeartRateSample(_ sample: HeartRateSample) {
        guard state == .countingDown, let startTicks, let startTime,
              currentRRStreamID?() == streamID,
              (isRemoteSource?() == true) == isRemoteMeasurement,
              sample.value > 0, sample.sensorContactStatus != .notDetected,
              !seenHeartRateSamples.contains(sample.id), let ticks = acquisitionTicks else { return }
        let elapsed = ticks - startTicks
        guard elapsed.isFinite, elapsed > 0, elapsed <= measurementDuration,
              elapsed >= (heartRateSampleOffsets.last ?? 0) else { return }
        seenHeartRateSamples.insert(sample.id)
        heartRateSampleOffsets.append(elapsed)
        heartRateSamples.append(HRVHeartRateSample(
            timestamp: startTime.addingTimeInterval(elapsed), bpm: sample.value
        ))
        minHeartRate = min(minHeartRate ?? sample.value, sample.value)
        maxHeartRate = max(maxHeartRate ?? sample.value, sample.value)
    }

    private func completeMeasurement() {
        guard let startTicks, let startTime else { return }
        if let error = HRVCalculator.qualityError(intervals: intervals, start: startTicks, duration: measurementDuration) {
            fail(reason: "quality_check", error)
            return
        }
        guard let result = HRVCalculator.rmssd(intervals.map(\.value)) else {
            fail(reason: "calculation", "Unable to calculate HRV from this recording. Please measure again.")
            return
        }
        timer?.invalidate()
        timer = nil
        hrvValue = result
        var weightedHeartRate = 0.0
        var coveredDuration: TimeInterval = 0
        for index in heartRateSamples.indices {
            let nextOffset = index + 1 < heartRateSamples.count
                ? heartRateSampleOffsets[index + 1] : measurementDuration
            let sampleDuration = min(
                nextOffset - heartRateSampleOffsets[index],
                HeartRateBluetoothManager.defaultHeartRateFreshnessInterval
            )
            weightedHeartRate += Double(heartRateSamples[index].bpm) * sampleDuration
            coveredDuration += sampleDuration
        }
        if coveredDuration > 0 {
            avgHeartRate = Int((weightedHeartRate / coveredDuration).rounded())
        }
        completedAt = startTime.addingTimeInterval(measurementDuration)
        state = .completed
        emitAnalytics(.hrvCompleted, [:])
        playCompletionFeedback()
        startLiveHeartRateUpdates()
    }

    private func fail(reason: String, _ message: String) {
        emitAnalytics(.hrvFailed, ["reason": reason, "stage": state == .countingDown ? "measurement" : "start"])
        timer?.invalidate()
        timer = nil
        hrvValue = nil
        completedAt = nil
        state = .error(message)
        startLiveHeartRateUpdates()
    }

    private func playCompletionFeedback() {
        // Haptic feedback - success notification (strong vibration)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        
        playCompletionSound()
        
        // Additional haptic feedback for extra emphasis (user may have eyes closed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
            impactGenerator.prepare()
            impactGenerator.impactOccurred()
        }
    }

    func startLiveHeartRateUpdates() {
        stopLiveHeartRateUpdates()
        liveHeartRateTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state != .countingDown else { return }
            self.currentBPM = self.currentHeartRate?()
        }
        RunLoop.main.add(liveHeartRateTimer!, forMode: .common)
    }

    func stopLiveHeartRateUpdates() {
        liveHeartRateTimer?.invalidate()
        liveHeartRateTimer = nil
    }

    func reset() {
        if state == .countingDown { emitAnalytics(.hrvCancelled, [:]) }
        timer?.invalidate()
        timer = nil
        state = .idle
        remainingTime = measurementDuration
        intervals.removeAll()
        seenIntervals.removeAll()
        heartRateSamples.removeAll()
        heartRateSampleOffsets.removeAll()
        seenHeartRateSamples.removeAll()
        hrvValue = nil
        avgHeartRate = nil
        minHeartRate = nil
        maxHeartRate = nil
        currentBPM = nil
        startTime = nil
        startTicks = nil
        streamID = nil
        completedAt = nil
        isRemoteMeasurement = false
    }

    func hrvRecord(recordId: UUID? = nil) -> HRVRecord? {
        // Provenance is captured at measurement start and remains attached to
        // the result even after the user disconnects or switches back to a device.
        guard canSaveMeasurement, let startTime, let completedAt, let hrvValue, hrvValue.isFinite else { return nil }
        return HRVRecord(
            id: recordId ?? UUID(), schemaVersion: HRVRecord.schemaVersion,
            startAt: startTime, endAt: completedAt, durationSeconds: measurementDuration,
            hrvValue: hrvValue, avgHr: avgHeartRate, minHr: minHeartRate, maxHr: maxHeartRate,
            hrSamples: heartRateSamples, rrIntervalsMs: intervals.map(\.value),
            source: "phone", appVersion: appVersionString(), createdAt: nowProvider(), updatedAt: nowProvider()
        )
    }

    private var acquisitionTicks: TimeInterval? {
        if let measurementTicks { return measurementTicks() }
        return ticksProvider()
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    deinit {
        timer?.invalidate()
        liveHeartRateTimer?.invalidate()
    }
}
