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
                            presentLogs(json: record.jsonString(), prefix: "BPM-HRV", date: record.startAt, source: .hrvDetail)
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
        .analyticsScreen(.hrvHistory)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Export Logs (for AI)") {
                        presentLogs(json: store.exportAllJSON(), prefix: "BPM-HRV-history", date: Date(), source: .hrvHistory)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(payload: payload)
        }
        .alert("Couldn’t Export Logs", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "Please try again.")
        }
    }

    private func presentLogs(json: String, prefix: String, date: Date, source: ShareAnalyticsContext.Source) {
        let analytics = ShareAnalyticsSession(context: ShareAnalyticsContext(source: source, format: .logs))
        do {
            let file = try JSONLogFile.create(json: json, prefix: prefix, date: date)
            sharePayload = SharePayload(items: [file], subject: "HRV Logs (JSON)", analytics: analytics)
        } catch {
            analytics.finish(completed: false, failed: true)
            shareError = "The JSON file couldn’t be created. Please try again."
        }
    }

    private func presentShare(items: [Any], subject: String) {
        let analytics = ShareAnalyticsSession(context: ShareAnalyticsContext(source: .hrvDetail, format: .plainText))
        sharePayload = SharePayload(items: items, subject: subject, analytics: analytics)
    }
}

private struct HRVHistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: HRVRecord

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))

        layout {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(record.hrvValue.map { String(Int($0.rounded())) } ?? "---")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("ms")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    heartRateSummary
                    VStack(alignment: .leading, spacing: 4) {
                        statLabel("Avg", value: record.avgHr)
                        statLabel("Min", value: record.minHr)
                        statLabel("Max", value: record.maxHr)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }

            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                Text(record.startAt, format: dateFormat)
                    .font(.subheadline.weight(.medium))
                Text(record.startAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var heartRateSummary: some View {
        HStack(spacing: 6) {
            statLabel("Avg", value: record.avgHr)
            Text("·")
            statLabel("Min", value: record.minHr)
            Text("·")
            statLabel("Max", value: record.maxHr)
        }
        .fixedSize()
    }

    private func statLabel(_ label: String, value: Int?) -> some View {
        Text("\(label) \(value.map(String.init) ?? "---")")
    }

    private var dateFormat: Date.FormatStyle {
        if Calendar.current.isDate(record.startAt, equalTo: Date(), toGranularity: .year) {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.month(.abbreviated).day().year()
    }

    private var accessibilitySummary: String {
        let hrv = record.hrvValue.map { "\(Int($0.rounded())) milliseconds" } ?? "unavailable"
        let average = record.avgHr.map(String.init) ?? "unavailable"
        let minimum = record.minHr.map(String.init) ?? "unavailable"
        let maximum = record.maxHr.map(String.init) ?? "unavailable"
        return "\(record.startAt.formatted(date: .abbreviated, time: .shortened)), HRV \(hrv), average heart rate \(average), minimum \(minimum), maximum \(maximum) beats per minute"
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
        .analyticsScreen(.hrvDetail)
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
