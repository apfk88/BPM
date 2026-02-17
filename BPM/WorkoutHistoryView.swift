import SwiftUI

struct WorkoutHistoryView: View {
    @ObservedObject var store: WorkoutStore
    @State private var sharePayload: SharePayload?

    var body: some View {
        List {
            if store.workouts.isEmpty {
                Text("No saved workouts yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.workouts) { workout in
                    NavigationLink {
                        WorkoutDetailView(
                            record: workout,
                            onShare: presentShare,
                            onDelete: {
                                store.deleteWorkout(workout)
                            }
                        )
                    } label: {
                        WorkoutHistoryRow(record: workout)
                    }
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Export Logs (for AI)") {
                        presentShare(items: [store.exportAllJSON()], subject: "Workout History Logs (for AI)")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items, subject: payload.subject)
        }
    }

    private func presentShare(items: [Any], subject: String) {
        sharePayload = SharePayload(items: items, subject: subject)
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let subject: String
}

private struct WorkoutHistoryRow: View {
    let record: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(title)
                        .font(.headline)
                } else {
                    Text(dateString(record.startAt))
                        .font(.headline)
                }
                Spacer()
                Text(formatDuration(record.durationSeconds))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(dateString(record.startAt))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                statChip(label: "Avg", value: record.avgHr)
                statChip(label: "Max", value: record.maxHr)
                if let hrr = record.hrr {
                    statChip(label: "HRR", value: hrr)
                }
            }
            if let caloriesSummaryText {
                Text(caloriesSummaryText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statChip(label: String, value: Int?) -> some View {
        Text("\(label) \(value.map(String.init) ?? "---")")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }

    private var caloriesSummaryText: String? {
        guard let total = record.caloriesTotal else { return nil }
        let totalText = "Total \(Int(round(total)))"
        if let active = record.caloriesActive {
            return "Calories: \(totalText) • Active \(Int(round(active)))"
        }
        return "Calories: \(totalText)"
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
}

private struct WorkoutDetailView: View {
    let record: WorkoutRecord
    let onShare: ([Any], String) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            Section(header: Text("Summary")) {
                if let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailRow(label: "Title", value: title)
                }
                if let notes = normalizedNotes {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes")
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

            Section(header: Text("Share")) {
                Button("Share Summary") {
                    onShare([record.summaryText()], "Workout Summary")
                }
                Button("Share Logs (for AI)") {
                    onShare([record.jsonString()], "Workout Logs (for AI)")
                }
            }

            Section {
                Button("Delete Workout", role: .destructive) {
                    showDeleteAlert = true
                }
            }
        }
        .navigationTitle("Workout")
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
