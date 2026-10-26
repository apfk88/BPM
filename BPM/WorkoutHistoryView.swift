import SwiftUI

struct WorkoutHistoryView: View {
    @ObservedObject var store: WorkoutStore
    @State private var selectedWorkoutID: UUID?
    @State private var sharePayload: SharePayload?
    @State private var shareError: String?

    var body: some View {
        List {
            if store.workouts.isEmpty {
                Text("No saved workouts yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.workouts) { workout in
                    Button {
                        selectedWorkoutID = workout.id
                    } label: {
                        WorkoutShareCardPreview(snapshot: WorkoutShareSnapshot(record: workout), style: .chart, compact: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens workout details")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteWorkout(workout)
                        } label: {
                            Text("Delete")
                        }
                    }
                }
            }
        }
        .navigationTitle("Workout History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedWorkoutID) { workoutID in
            if let workout = store.workouts.first(where: { $0.id == workoutID }) {
                WorkoutDetailView(
                    initialRecord: workout,
                    store: store,
                    onDelete: {
                        store.deleteWorkout(workout)
                    }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Export Logs (for AI)") {
                        presentLogs(json: store.exportAllJSON(), prefix: "BPM-workout-history", date: Date(),
                                    subject: "Workout History Logs (JSON)")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items, subject: payload.subject)
        }
        .alert("Couldn’t Export Logs", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "Please try again.")
        }
    }

    private func presentLogs(json: String, prefix: String, date: Date, subject: String) {
        do {
            let file = try JSONLogFile.create(json: json, prefix: prefix, date: date)
            presentShare(items: [file], subject: subject)
        } catch {
            shareError = "The JSON file couldn’t be created. Please try again."
        }
    }

    private func presentShare(items: [Any], subject: String) {
        sharePayload = SharePayload(items: items, subject: subject)
    }
}

private struct WorkoutDetailView: View {
    let initialRecord: WorkoutRecord
    @ObservedObject var store: WorkoutStore
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false
    @State private var showExpandedHeartRateChart = false
    @State private var isEditingWorkout = false
    @State private var isSharingWorkout = false

    private var record: WorkoutRecord {
        store.workouts.first(where: { $0.id == initialRecord.id }) ?? initialRecord
    }

    var body: some View {
        workoutLog
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isEditingWorkout = true } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit workout")
                .accessibilityIdentifier("editSavedWorkout")
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSharingWorkout = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share workout")
                .accessibilityIdentifier("openWorkoutShareDrawer")
            }
        }
        .sheet(isPresented: $isEditingWorkout) {
            WorkoutDetailsEditor(record: record, store: store)
        }
        .sheet(isPresented: $isSharingWorkout) {
            WorkoutShareDrawer(record: record)
        }
        .fullScreenCover(isPresented: $showExpandedHeartRateChart) {
            ExpandedHeartRateChartView(record: record)
        }
        .alert("Delete Workout?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("This will permanently remove the workout from history.")
        }
    }

    private var workoutLog: some View {
        List {
            Section(header: Text("Heart Rate")) {
                if record.hrSamples.isEmpty {
                    Text("No heart rate samples saved for this workout.")
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        showExpandedHeartRateChart = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            WorkoutRecordHeartRateChartView(record: record)
                                .allowsHitTesting(false)

                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.black.opacity(0.7), in: Circle())
                                .padding(4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(height: 220)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Expand heart rate chart")
                    .accessibilityHint("Opens a full-screen chart with zoom and pan controls")
                }
            }

            Section(header: Text("Summary")) {
                if let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailRow(label: "Title", value: title)
                }
                if let notes = normalizedNotes {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                        Text(notes)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                detailRow(label: "Start", value: dateString(record.startAt))
                detailRow(label: "End", value: dateString(record.endAt))
                detailRow(label: "Duration", value: formatDuration(record.durationSeconds))
                detailRow(label: "Avg BPM", value: record.avgHr.map(String.init))
                detailRow(label: "Max BPM", value: record.maxHr.map(String.init))
                detailRow(label: "Min BPM", value: record.minHr.map(String.init))
                detailRow(label: "HRR (2 min)", value: record.hrr.map(String.init))
                if let caloriesTotal = record.caloriesTotal {
                    detailRow(label: "Calories (Total)", value: String(Int(round(caloriesTotal))))
                }
                if let caloriesActive = record.caloriesActive {
                    detailRow(label: "Calories (Active)", value: String(Int(round(caloriesActive))))
                }
            }

            if !record.zones.isEmpty {
                Section(header: Text("Zones")) {
                    ForEach(record.zones) { zone in
                        HStack {
                            Text("Z\(zone.zone)")
                            Spacer()
                            Text(formatDuration(zone.duration))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if !record.sets.isEmpty {
                Section(header: Text("Sets")) {
                    ForEach(record.sets) { set in
                        let hrLabel = set.isRestSet ? "Min" : "Max"
                        let hrValue = set.isRestSet ? set.minBpm : set.maxBpm

                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.label)
                                    .font(.subheadline)
                                Text("\(hrLabel) BPM \(hrValue.map(String.init) ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(formatDuration(set.setTime))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Delete Workout", role: .destructive) {
                    showDeleteAlert = true
                }
            }
        }
        .accessibilityIdentifier("workoutLogTab")
    }

    private func detailRow(label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundColor(.secondary)
        }
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var normalizedNotes: String? {
        let value = record.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

#Preview {
    WorkoutHistoryView(store: WorkoutStore())
}
