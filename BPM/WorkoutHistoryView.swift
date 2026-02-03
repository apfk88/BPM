import SwiftUI

struct WorkoutHistoryView: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: [Any] = []
    @State private var shareSubject: String = ""
    @State private var showShareSheet = false

    var body: some View {
        NavigationView {
            List {
                if store.workouts.isEmpty {
                    Text("No saved workouts yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.workouts) { workout in
                        NavigationLink {
                            WorkoutDetailView(
                                record: workout,
                                onShare: presentShare
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
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                Button("AI Export") {
                    presentShare(items: [store.exportAllJSON()], subject: "Workout History Logs (for AI)")
                }
            }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems, subject: shareSubject)
        }
    }

    private func presentShare(items: [Any], subject: String) {
        shareItems = items
        shareSubject = subject
        showShareSheet = true
    }
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
                if let total = record.caloriesTotal {
                    Text("Cal \(Int(round(total)))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statChip(label: String, value: Int?) -> some View {
        Text("\(label) \(value.map(String.init) ?? "---")")
            .font(.subheadline)
            .foregroundColor(.secondary)
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

    var body: some View {
        List {
            Section(header: Text("Summary")) {
                if let title = record.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailRow(label: "Title", value: title)
                }
                detailRow(label: "Start", value: dateString(record.startAt))
                detailRow(label: "End", value: dateString(record.endAt))
                detailRow(label: "Duration", value: formatDuration(record.durationSeconds))
                detailRow(label: "Avg BPM", value: record.avgHr.map(String.init))
                detailRow(label: "Max BPM", value: record.maxHr.map(String.init))
                detailRow(label: "Min BPM", value: record.minHr.map(String.init))
                if let caloriesTotal = record.caloriesTotal {
                    detailRow(label: "Calories", value: String(Int(round(caloriesTotal))))
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
                        HStack {
                            Text(set.label)
                                .font(.subheadline)
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
        }
        .navigationTitle("Workout")
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
}

#Preview {
    WorkoutHistoryView(store: WorkoutStore())
}
