import SwiftUI

struct RecoveryWindow: Identifiable {
    let sessionID: UUID
    let start: Date
    let end: Date

    struct ID: Hashable {
        let sessionID: UUID
        let start: Date
    }

    var id: ID { ID(sessionID: sessionID, start: start) }

    // A saved workout can sit entirely between two readings. Split at its
    // boundaries even when there are no samples inside the saved interval.
    static func available(sessionID: UUID, samples: [HeartRateSample], excluding intervals: [DateInterval]) -> [Self] {
        let excluded = intervals.sorted { $0.start < $1.start }
        var index = 0
        var first: Date?
        var last: Date?
        var windows: [Self] = []
        func finishWindow() {
            if let first, let last, first < last {
                windows.append(Self(sessionID: sessionID, start: first, end: last))
            }
            first = nil
            last = nil
        }
        for sample in samples {
            while index < excluded.count, sample.timestamp > excluded[index].end {
                finishWindow()
                index += 1
            }
            if index < excluded.count, sample.timestamp >= excluded[index].start {
                finishWindow()
                continue
            }
            first = first ?? sample.timestamp
            last = sample.timestamp
        }
        finishWindow()
        return windows
    }
}

struct RecoverWorkoutView: View {
    @ObservedObject var store: WorkoutStore
    var currentWorkoutInterval: () -> DateInterval?
    var onSave: (WorkoutRecord) -> Void
    var archive = PassiveHeartRateArchive.shared
    @State private var windows: [RecoveryWindow]?
    @State private var selection: RecoveryWindow?
    @State private var savedWorkout: WorkoutRecord?
    @State private var showSavedWorkout = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError)
                    Button("Try Again") { Task { await load() } }
                }
            } else if let windows, !windows.isEmpty {
                Section {
                    ForEach(windows) { window in
                        Button { selection = window } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(window.start.formatted(.dateTime.weekday().month().day()))
                                        .font(.headline)
                                    Text((window.start..<window.end).formatted(.interval.hour().minute()))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Duration.seconds(window.end.timeIntervalSince(window.start)).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1))))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recoveryWindow")
                    }
                } header: {
                    Text("Available readings")
                } footer: {
                    Text("Choose a recording to set the start and end of your workout. Readings stay on this device for seven days.")
                }
            } else if windows != nil {
                ContentUnavailableView("No unused readings", systemImage: "waveform.path.ecg",
                    description: Text("Connect your heart rate monitor to BPM. If you forget to start a workout, you can recover its readings here for seven days."))
                    .listRowBackground(Color.clear)
            } else {
                ProgressView("Loading readings")
            }
        }
        .navigationTitle("Recover a Workout")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.workouts.map(\.id)) { await load() }
        .refreshable { await load() }
        .sheet(item: $selection, onDismiss: {
            if savedWorkout != nil { showSavedWorkout = true }
            Task { await load() }
        }) { window in
            RecoveryEditor(window: window, archive: archive, store: store, currentWorkoutInterval: currentWorkoutInterval) { record in
                savedWorkout = record
                onSave(record)
                selection = nil
            }
        }
        .navigationDestination(isPresented: $showSavedWorkout) {
            if let record = savedWorkout {
                WorkoutDetailView(initialRecord: record, store: store, onDelete: { store.deleteWorkout(record) })
            }
        }
        .onChange(of: showSavedWorkout) { _, showing in
            if !showing { savedWorkout = nil }
        }
    }

    private func load() async {
        do {
            let sessions = try await archive.sessions()
            var occupied = store.workouts.map { DateInterval(start: $0.startAt, end: max($0.startAt, $0.endAt)) }
            if let current = currentWorkoutInterval() { occupied.append(current) }
            var available: [RecoveryWindow] = []
            for session in sessions where session.sampleCount > 1 && session.endAt > session.startAt {
                let overlaps = occupied.filter { $0.end >= session.startAt && $0.start <= session.endAt }
                if overlaps.isEmpty {
                    available.append(RecoveryWindow(sessionID: session.id, start: session.startAt, end: session.endAt))
                } else if !overlaps.contains(where: { $0.start <= session.startAt && $0.end >= session.endAt }) {
                    let samples = try await archive.samples(for: session.id)
                    available += RecoveryWindow.available(sessionID: session.id, samples: samples, excluding: overlaps)
                }
            }
            try Task.checkCancellation()
            windows = available.sorted { $0.start > $1.start }
            loadError = nil
        } catch is CancellationError { }
        catch { loadError = "BPM couldn’t load the readings on this device." }
    }
}

private struct RecoveryEditor: View {
    let window: RecoveryWindow
    let archive: PassiveHeartRateArchive
    let store: WorkoutStore
    let currentWorkoutInterval: () -> DateInterval?
    let onSave: (WorkoutRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var samples: [HeartRateSample]?
    @State private var preview: WorkoutRecord?
    @State private var saving = false
    @State private var message: String?

    init(window: RecoveryWindow, archive: PassiveHeartRateArchive, store: WorkoutStore,
         currentWorkoutInterval: @escaping () -> DateInterval?, onSave: @escaping (WorkoutRecord) -> Void) {
        self.window = window
        self.archive = archive
        self.store = store
        self.currentWorkoutInterval = currentWorkoutInterval
        self.onSave = onSave
        _start = State(initialValue: window.start)
        _end = State(initialValue: window.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $start, in: window.start...end, displayedComponents: dateComponents)
                        .accessibilityIdentifier("recoveryStart")
                    DatePicker("End", selection: $end, in: start...window.end, displayedComponents: dateComponents)
                        .accessibilityIdentifier("recoveryEnd")
                } header: {
                    Text(window.start.formatted(date: .complete, time: .omitted))
                }
                if let preview {
                    Section {
                        LabeledContent("Duration", value: Duration.seconds(preview.durationSeconds).formatted(.time(pattern: .hourMinuteSecond)))
                        if let avg = preview.avgHr { LabeledContent("Average", value: "\(avg) BPM") }
                        if let max = preview.maxHr { LabeledContent("Peak", value: "\(max) BPM") }
                        let snapshot = WorkoutShareSnapshot(record: preview)
                        HeartRateTimelineChart(dataPoints: snapshot.plotPoints.map {
                            HeartRateChartDataPoint(time: $0.time, bpm: $0.bpm, segment: $0.segment, validUntil: $0.validUntil)
                        }, segments: [], maxTime: preview.durationSeconds)
                        .frame(height: 150)
                        .accessibilityLabel("Heart rate during the selected time")
                    }
                } else if samples != nil {
                    Text("Choose a range with at least two heart rate readings.")
                } else if message == nil {
                    ProgressView("Loading readings")
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Workout", action: save)
                        .disabled(preview == nil || saving)
                        .accessibilityIdentifier("saveRecoveredWorkout")
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .task {
                do {
                    let readings = try await archive.samples(for: window.sessionID)
                    try Task.checkCancellation()
                    samples = readings.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
                    updatePreview()
                } catch is CancellationError { }
                catch { message = "BPM couldn’t read this recording. Close it and try again." }
            }
            .onChange(of: start) { _, _ in updatePreview() }
            .onChange(of: end) { _, _ in updatePreview() }
        }
    }

    private var dateComponents: DatePickerComponents {
        Calendar.current.isDate(window.start, inSameDayAs: window.end) ? .hourAndMinute : [.date, .hourAndMinute]
    }

    private func updatePreview() {
        guard let samples else { return }
        message = nil
        preview = RetrospectiveWorkout.makeRecord(sessionID: window.sessionID, startAt: start, endAt: end,
                                                  samples: samples, zoneConfig: HeartRateZoneStorage.shared.effectiveConfig)
    }

    private func save() {
        guard let preview, !saving else { return }
        if let current = currentWorkoutInterval(), current.start <= preview.endAt, current.end >= preview.startAt {
            message = "This time is already part of your current workout."
            return
        }
        saving = true
        store.saveRetrospectiveWorkout(preview) { result in
            saving = false
            switch result {
            case .success(let record): onSave(record)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}
