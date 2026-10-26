import SwiftUI

struct HRVHistoryView: View {
    @ObservedObject var store: HRVStore
    @State private var sharePayload: SharePayload?
    @State private var shareError: String?

    var body: some View {
        List {
            if store.records.isEmpty {
                Text("No HRV sessions yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.records) { record in
                    NavigationLink {
                        HRVDetailView(record: record, onShare: presentShare, onShareLogs: {
                            presentLogs(json: record.jsonString(), prefix: "BPM-HRV", date: record.startAt)
                        })
                    } label: {
                        HRVHistoryRow(record: record)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteRecord(record)
                        } label: {
                            Text("Delete")
                        }
                    }
                }
            }
        }
        .navigationTitle("HRV History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Export Logs (for AI)") {
                        presentLogs(json: store.exportAllJSON(), prefix: "BPM-HRV-history", date: Date())
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

    private func presentLogs(json: String, prefix: String, date: Date) {
        do {
            let file = try JSONLogFile.create(json: json, prefix: prefix, date: date)
            presentShare(items: [file], subject: "HRV Logs (JSON)")
        } catch {
            shareError = "The JSON file couldn’t be created. Please try again."
        }
    }

    private func presentShare(items: [Any], subject: String) {
        sharePayload = SharePayload(items: items, subject: subject)
    }
}

private struct HRVHistoryRow: View {
    let record: HRVRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dateString(record.startAt))
                    .font(.headline)
                Spacer()
                if let hrv = record.hrvValue {
                    Text("\(Int(hrv.rounded())) ms")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                statChip(label: "Avg", value: record.avgHr)
                statChip(label: "Min", value: record.minHr)
                statChip(label: "Max", value: record.maxHr)
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
}

private struct HRVDetailView: View {
    let record: HRVRecord
    let onShare: ([Any], String) -> Void
    let onShareLogs: () -> Void

    var body: some View {
        List {
            Section(header: Text("Summary")) {
                detailRow(label: "Start", value: dateString(record.startAt))
                detailRow(label: "End", value: dateString(record.endAt))
                detailRow(label: "Duration", value: formatDuration(record.durationSeconds))
                if let hrv = record.hrvValue {
                    detailRow(label: "HRV (RMSSD)", value: "\(Int(hrv.rounded())) ms")
                }
                detailRow(label: "Avg BPM", value: record.avgHr.map(String.init))
                detailRow(label: "Min BPM", value: record.minHr.map(String.init))
                detailRow(label: "Max BPM", value: record.maxHr.map(String.init))
            }

            Section(header: Text("Share")) {
                Button("Share Summary") {
                    onShare([record.summaryText()], "HRV Summary")
                }
                Button("Share Logs (for AI)") {
                    onShareLogs()
                }
            }
        }
        .navigationTitle("HRV Session")
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
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    HRVHistoryView(store: HRVStore())
}
