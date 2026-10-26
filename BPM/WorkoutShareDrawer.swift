import SwiftUI

struct SavedWorkoutShareRequest: Identifiable {
    let record: WorkoutRecord
    let activityOption: HealthKitActivityOption
    var id: UUID { record.id }
}

/// One share picker for saved workouts and the end-of-workout flow.
struct WorkoutShareDrawer: View {
    let record: WorkoutRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selection: ShareFormat? = .chart
    @State private var selectedCard: WorkoutShareStyle?
    @State private var sharePayload: SharePayload?
    @State private var exportError: String?

    private enum ShareFormat: Int, CaseIterable, Identifiable {
        case chart, stats, text, logs
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .chart: "Chart Card"
            case .stats: "Stats Card"
            case .text: "Plain Text"
            case .logs: "Logs"
            }
        }
        var subtitle: String {
            switch self {
            case .chart: "Your heart rate over time"
            case .stats: "Average, peak, duration and top zone"
            case .text: "Your workout details as text"
            case .logs: "Detailed workout data to share with AI"
            }
        }
        var action: String {
            switch self {
            case .chart: "Share Chart"
            case .stats: "Share Stats"
            case .text: "Share Text"
            case .logs: "Share Logs"
            }
        }
    }

    private var currentFormat: ShareFormat { selection ?? .chart }
    private let coral = Color(red: 1, green: 0.39, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Share").font(.title3.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.07), in: Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close sharing")
                .accessibilityIdentifier("closeWorkoutShareDrawer")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            GeometryReader { geometry in
                if verticalSizeClass == .compact {
                    HStack(spacing: 20) {
                        carousel
                        ScrollView {
                            VStack(spacing: 12) { formatHeading; pageDots; shareButton }
                                .padding(.vertical, 12)
                        }
                        .frame(width: min(300, geometry.size.width * 0.4))
                        .padding(.trailing, 20)
                    }
                } else {
                    VStack(spacing: 12) {
                        formatHeading.padding(.top, 12)
                        carousel
                        pageDots
                        shareButton.padding(.horizontal, 20).padding(.bottom, 12)
                    }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .sheet(item: $selectedCard) { style in
            WorkoutShareCardEditor(record: record, style: style)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items, subject: payload.subject)
        }
        .alert("Couldn’t Export Logs", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
    }

    private var formatHeading: some View {
        VStack(spacing: 5) {
            Text(currentFormat.title).font(.headline)
                .accessibilityIdentifier("workoutShareFormat")
            Text(currentFormat.subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var carousel: some View {
        GeometryReader { geometry in
            let cardWidth = min(260, geometry.size.width * 0.68, max(1, (geometry.size.height - 30) / 1.25))
            let pageWidth = cardWidth + 16
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(ShareFormat.allCases) { format in
                        preview(format)
                            .frame(width: cardWidth, height: cardWidth * 1.25)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                            .frame(width: pageWidth, height: geometry.size.height)
                            .id(format)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (geometry.size.width - pageWidth) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("workoutShareCarousel")
        }
    }

    @ViewBuilder
    private func preview(_ format: ShareFormat) -> some View {
        switch format {
        case .chart, .stats:
            Button { selectedCard = format == .chart ? .chart : .stats } label: {
                WorkoutShareCardPreview(snapshot: WorkoutShareSnapshot(record: record),
                                        style: format == .chart ? .chart : .stats)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(format == .chart ? "openChartCard" : "openStatsCard")
            .accessibilityHint("Edit the title and range before sharing")
        case .text:
            ScrollView {
                Text(record.summaryText())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityIdentifier("workoutTextSummary")
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
        case .logs:
            VStack(spacing: 20) {
                Image(systemName: "doc")
                    .font(.system(size: 72, weight: .ultraLight))
                    .overlay {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 24, weight: .medium)).offset(y: 8)
                    }
                Text("Workout.json").font(.callout.monospaced())
                Text(WorkoutShareSnapshot(record: record).title)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            ForEach(ShareFormat.allCases) { format in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { selection = format }
                } label: {
                    Circle().fill(currentFormat == format ? .white : .white.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .frame(width: 26, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(format.title)
                .accessibilityIdentifier("shareFormat\(format.rawValue)")
                .accessibilityAddTraits(currentFormat == format ? .isSelected : [])
            }
        }
    }

    private var shareButton: some View {
        Button(action: shareSelectedFormat) {
            Text(currentFormat.action)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(coral)
        .foregroundStyle(.black)
        .controlSize(.large)
        .accessibilityIdentifier("shareSelectedWorkoutFormat")
    }

    private func shareSelectedFormat() {
        switch currentFormat {
        case .chart: selectedCard = .chart
        case .stats: selectedCard = .stats
        case .text: sharePayload = SharePayload(items: [record.summaryText()], subject: "Workout Summary")
        case .logs:
            do {
                let file = try JSONLogFile.create(json: record.jsonString(), prefix: "BPM-workout", date: record.startAt)
                sharePayload = SharePayload(items: [file], subject: "Workout Logs (JSON)")
            } catch {
                exportError = "The JSON file couldn’t be created. Please try again."
            }
        }
    }
}

#if DEBUG
#Preview {
    WorkoutShareDrawer(record: WorkoutSharePreviewFixture.record)
}
#endif
