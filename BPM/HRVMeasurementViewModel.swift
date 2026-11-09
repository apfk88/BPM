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
    @Published var state: HRVMeasurementState = .idle {
        didSet {
            if state != oldValue { sharingRevision = UUID().uuidString }
        }
    }
    @Published var remainingTime: TimeInterval = 120
    @Published var hrvValue: Double?
    @Published var avgHeartRate: Int?
    @Published var minHeartRate: Int?
    @Published var maxHeartRate: Int?
    @Published var currentBPM: Int?
    @Published private(set) var isRemoteMeasurement = false
    @Published private(set) var isMirroringSharedMeasurement = false
    private(set) var sharingRevision = UUID().uuidString

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
    private var measurementSensorIdentity: SensorAnalyticsIdentity?
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
    var startReadiness: (() -> HRVStartReadiness)?
    var currentSensorAnalyticsIdentity: (() -> SensorAnalyticsIdentity?)?

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

    /// Configure acquisition at the app level so a viewer can start a host
    /// measurement before the host has ever opened the HRV screen.
    func configureLocalSource(_ manager: HeartRateBluetoothManager) {
        if isMirroringSharedMeasurement { reset() }
        currentHeartRate = { [weak manager] in manager?.freshHeartRate }
        getRRIntervals = { [weak manager] in manager?.rrIntervals ?? [] }
        supportsRRIntervals = { [weak manager] in manager?.supportsRRIntervals == true }
        currentRRStreamID = { [weak manager] in
            guard manager?.hasActiveDataSource == true else { return nil }
            return manager?.rrStreamID
        }
        measurementTicks = nil
        isRemoteSource = { false }
        currentSensorAnalyticsIdentity = { [weak manager] in manager?.sensorAnalyticsIdentity }
        startReadiness = { [weak manager, weak self] in
            .local(isConnected: manager?.hasActiveDataSource == true,
                   hasSensorContact: manager?.sensorContactStatus != .notDetected,
                   hasFreshHeartRate: manager?.freshHeartRate != nil,
                   supportsRR: manager?.supportsRRIntervals == true,
                   latestRRTicks: manager?.rrIntervals.last?.receivedTicks,
                   nowTicks: self?.ticksProvider() ?? MeasurementClock.ticks)
        }
        observeHeartRate(from: manager.heartRateMeasurements.eraseToAnyPublisher())
    }

    func sharedSnapshot(isPresented: Bool, allowsRemoteControl: Bool = true) -> SharedHRVSnapshot {
        let sharedState: SharedHRVSnapshot.State
        switch state {
        case .idle: sharedState = .idle
        case .countingDown: sharedState = .measuring
        case .completed: sharedState = .completed
        case .error: sharedState = .error
        }
        let readiness = startReadiness?() ?? .local(
            isConnected: currentRRStreamID?() != nil,
            hasSensorContact: true,
            hasFreshHeartRate: currentHeartRate?() != nil,
            supportsRR: supportsRRIntervals?() == true,
            latestRRTicks: getRRIntervals?().last?.receivedTicks,
            nowTicks: acquisitionTicks ?? .nan
        )
        return SharedHRVSnapshot(
            revision: sharingRevision, isPresented: isPresented, state: sharedState,
            remainingTime: remainingTime, hrvValue: hrvValue,
            avgHeartRate: avgHeartRate, minHeartRate: minHeartRate, maxHeartRate: maxHeartRate,
            currentBPM: state == .idle && !isMirroringSharedMeasurement ? currentHeartRate?() : currentBPM,
            readinessReason: readiness.reason, errorMessage: errorMessage,
            allowsRemoteControl: allowsRemoteControl && !isMirroringSharedMeasurement && !isRemoteMeasurement
        )
    }

    @discardableResult
    func applySharedControl(_ action: SharedWorkoutAction) -> Bool {
        guard sharedSnapshot(isPresented: true).permits(action) else { return false }
        switch action {
        case .hrvStart: startMeasurement()
        case .hrvCancel, .hrvReset: reset(); startLiveHeartRateUpdates()
        default: return false
        }
        return true
    }

    /// Mirroring never starts acquisition, runs quality checks, emits measurement
    /// analytics, or creates a record in the viewer's history.
    func mirrorSharedMeasurement(_ snapshot: SharedHRVSnapshot?, age: TimeInterval = 0) {
        if !isMirroringSharedMeasurement { reset() }
        isMirroringSharedMeasurement = true
        isRemoteMeasurement = true
        timer?.invalidate()
        timer = nil
        stopLiveHeartRateUpdates()
        heartRateCancellable = nil
        guard let snapshot, snapshot.isValid else {
            state = .idle
            remainingTime = measurementDuration
            hrvValue = nil
            avgHeartRate = nil
            minHeartRate = nil
            maxHeartRate = nil
            currentBPM = nil
            return
        }
        remainingTime = snapshot.remainingTime(after: age)
        hrvValue = snapshot.state == .completed ? snapshot.hrvValue : nil
        avgHeartRate = snapshot.avgHeartRate
        minHeartRate = snapshot.minHeartRate
        maxHeartRate = snapshot.maxHeartRate
        currentBPM = snapshot.currentBPM
        switch snapshot.state {
        case .idle: state = .idle
        case .measuring: state = .countingDown
        case .completed: state = .completed
        case .error: state = .error(snapshot.errorMessage ?? "Unable to complete HRV measurement. Please try again.")
        }
    }

    func startMeasurement() {
        guard !isMirroringSharedMeasurement, state != .countingDown else { return }
        reset()
        isRemoteMeasurement = isRemoteSource?() == true
        measurementSensorIdentity = isRemoteMeasurement ? nil : currentSensorAnalyticsIdentity?()
        if let readiness = startReadiness?(), !readiness.isReady {
            fail(.readiness(readiness.reason), readiness.message)
            return
        }
        let message = isRemoteMeasurement
            ? "HRV requires fresh raw beat intervals from the shared monitor. Check the monitor connection and keep sharing open."
            : "HRV requires fresh beat intervals from your connected heart rate monitor. Check your strap connection and contact, then try again."
        guard supportsRRIntervals?() == true else {
            fail(.start(.rrUnavailable), message)
            return
        }
        guard currentHeartRate?() != nil || isRemoteMeasurement else {
            fail(.start(.heartRateUnavailable), message)
            return
        }
        guard let currentStream = currentRRStreamID?() else {
            fail(.start(.streamUnavailable), message)
            return
        }
        guard let ticks = acquisitionTicks, ticks.isFinite else {
            fail(.start(.clockUnavailable), message)
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
        emitAnalytics(.hrvStart, sourceParameters)
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMeasurement() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Timer callbacks only refresh the display; monotonic time defines the window.
    func updateMeasurement() {
        guard !isMirroringSharedMeasurement, state == .countingDown, let startTicks else { return }
        let message = isRemoteMeasurement
            ? "Shared beat data was interrupted or the monitor changed. Check the connection and measure again."
            : "The sensor connection or contact changed during measurement. Check your strap and measure again."
        guard (isRemoteSource?() == true) == isRemoteMeasurement else {
            fail(.measurement(.sourceChanged), message)
            return
        }
        guard let currentStream = currentRRStreamID?() else {
            fail(.measurement(.streamUnavailable), message)
            return
        }
        guard currentStream == streamID else {
            fail(.measurement(.streamChanged), message)
            return
        }
        guard supportsRRIntervals?() == true else {
            fail(.measurement(.rrUnavailable), message)
            return
        }
        guard let nowTicks = acquisitionTicks, nowTicks.isFinite else {
            fail(.measurement(.clockUnavailable), message)
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
            fail(.dataStopped(receivedBeats: !intervals.isEmpty), "Beat data stopped during measurement. Check your strap connection and measure again.")
        }
    }

    func observeHeartRate(from measurements: AnyPublisher<HeartRateSample, Never>) {
        heartRateCancellable = measurements.sink { [weak self] sample in
            self?.recordHeartRateSample(sample)
        }
    }

    /// Capture every received sensor value; UI timer polls are not measurements.
    func recordHeartRateSample(_ sample: HeartRateSample) {
        guard !isMirroringSharedMeasurement, state == .countingDown, let startTicks, let startTime,
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
        if let issue = HRVCalculator.qualityIssue(intervals: intervals, start: startTicks, duration: measurementDuration) {
            fail(.quality(issue), issue.message)
            return
        }
        guard let result = HRVCalculator.rmssd(intervals.map(\.value)) else {
            fail(.calculation, "Unable to calculate HRV from this recording. Please measure again.")
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
        emitAnalytics(.hrvCompleted, sourceParameters)
        playCompletionFeedback()
        startLiveHeartRateUpdates()
    }

    private func fail(_ failure: Failure, _ message: String) {
        emitAnalytics(.hrvFailed, sourceParameters.merging(failure.parameters) { _, new in new })
        timer?.invalidate()
        timer = nil
        hrvValue = nil
        completedAt = nil
        state = .error(message)
        startLiveHeartRateUpdates()
    }

    private var sourceParameters: [String: String] {
        var parameters = ["source": isRemoteMeasurement ? "shared" : "local"]
        if !isRemoteMeasurement, let measurementSensorIdentity {
            parameters.merge(measurementSensorIdentity.parameters) { _, new in new }
        }
        return parameters
    }

    private enum AcquisitionFailure: String {
        // RR availability includes freshness/contact. Do not imply the monitor
        // lacks RR capability when the source only reports current availability.
        case rrUnavailable = "rr_unavailable"
        case heartRateUnavailable = "heart_rate_unavailable"
        case streamUnavailable = "stream_unavailable"
        case clockUnavailable = "clock_unavailable"
        case streamChanged = "stream_changed"
        case sourceChanged = "source_changed"
    }

    private enum Failure {
        case readiness(HRVStartReadiness.Reason)
        case start(AcquisitionFailure)
        case measurement(AcquisitionFailure)
        case dataStopped(receivedBeats: Bool)
        case quality(HRVCalculator.QualityIssue)
        case calculation

        var parameters: [String: String] {
            // Keep the established reason families; detail and stage provide
            // bounded diagnostics with no readings, timing values, or IDs.
            switch self {
            case .readiness(let reason):
                return ["reason": "sensor_unavailable", "stage": "start", "detail": reason.rawValue]
            case .start(let issue):
                return ["reason": "sensor_unavailable", "stage": "start", "detail": issue.rawValue]
            case .measurement(let issue):
                return ["reason": "sensor_changed", "stage": "measurement", "detail": issue.rawValue]
            case .dataStopped(let receivedBeats):
                return ["reason": "data_stopped", "stage": "measurement",
                        "detail": receivedBeats ? "beat_data_stopped" : "no_beats_received"]
            case .quality(let issue):
                return ["reason": "quality_check", "stage": "validation", "detail": issue.rawValue]
            case .calculation:
                return ["reason": "calculation", "stage": "calculation", "detail": "invalid_result"]
            }
        }
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
        guard !isMirroringSharedMeasurement else { return }
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
        if state == .countingDown && !isMirroringSharedMeasurement { emitAnalytics(.hrvCancelled, sourceParameters) }
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
        isMirroringSharedMeasurement = false
        sharingRevision = UUID().uuidString
        measurementSensorIdentity = nil
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
