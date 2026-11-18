import SwiftUI

/// Share formats opened explicitly from a saved workout.
struct WorkoutShareDrawer: View {
    let record: WorkoutRecord
    let source: ShareAnalyticsContext.Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: ShareFormat? = .chart
    @State private var selectedCard: WorkoutShareStyle?
    @State private var accent: WorkoutShareAccent = .white
    @State private var sharePayload: SharePayload?
    @State private var didShare = false
    @State private var shareSheetDismissed = false
    @State private var exportError: String?
    @State private var didTrackOpen = false
    @StateObject private var pageDraft: WorkoutPageShareDraft

    init(record: WorkoutRecord, source: ShareAnalyticsContext.Source, pageService: WorkoutPageService? = nil) {
        self.record = record
        self.source = source
        _pageDraft = StateObject(wrappedValue: WorkoutPageShareDraft(record: record, service: pageService))
    }

    private enum ShareFormat: Int, CaseIterable, Identifiable {
        case chart, stats, text, logs
        var id: Int { rawValue }
        var analyticsFormat: ShareAnalyticsContext.Format {
            switch self {
            case .chart: .chartCard
            case .stats: .statsCard
            case .text: .plainText
            case .logs: .logs
            }
        }
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
    private var isCardSelected: Bool { currentFormat == .chart || currentFormat == .stats }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Share").font(.title3.bold())
                Spacer()
                Button {
                    pageDraft.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.07), in: Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close sharing")
                .accessibilityIdentifier("closeWorkoutShareDrawer")
                .disabled(pageDraft.isPreparingShare)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            GeometryReader { geometry in
                if verticalSizeClass == .compact {
                    HStack(spacing: 20) {
                        carousel
                        ScrollView {
                            VStack(spacing: 12) {
                                formatHeading
                                pageDots
                                WorkoutPageSharingOptions(draft: pageDraft)
                                shareActions
                            }
                                .padding(.vertical, 12)
                        }
                        .frame(width: min(300, geometry.size.width * 0.4))
                        .padding(.trailing, 20)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            formatHeading.padding(.top, 12)
                            carousel.frame(height: 355)
                            pageDots
                            WorkoutPageSharingOptions(draft: pageDraft).padding(.horizontal, 20)
                            shareActions.padding(.horizontal, 20)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .onAppear {
            guard !didTrackOpen else { return }
            didTrackOpen = true
            analyticsContext(for: currentFormat).signal(.sharePickerOpened)
        }
        .onChange(of: selection) { _, format in
            if let format { analyticsContext(for: format).signal(.shareFormatSelected) }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .preferredColorScheme(.dark)
        .presentationDetents(verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
                             ? [.large] : [.height(700), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .sheet(item: $selectedCard, onDismiss: sharingSheetDidDismiss) { style in
            WorkoutShareCardEditor(record: record, style: style, source: source, accent: $accent, pageDraft: pageDraft) {
                didShare = true
            }
        }
        .sheet(item: $sharePayload, onDismiss: sharingSheetDidDismiss) { payload in
            ShareSheet(payload: payload) { didShare = true }
        }
        .onChange(of: didShare) { _, _ in dismissAfterSharing() }
        .alert("Couldn’t Share Workout", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
        .workoutPageShareAlerts(pageDraft, isActive: selectedCard == nil)
    }

    private func sharingSheetDidDismiss() {
        shareSheetDismissed = true
        dismissAfterSharing()
    }

    private func dismissAfterSharing() {
        // Let each presented sheet finish closing before dismissing its parent.
        if didShare && shareSheetDismissed { dismiss() }
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
                            .opacity(format == currentFormat ? 1 : 0.3)
                            .animation(.easeInOut(duration: 0.2), value: currentFormat)
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
            .allowsHitTesting(!pageDraft.isPreparingShare)
        }
    }

    @ViewBuilder
    private func preview(_ format: ShareFormat) -> some View {
        switch format {
        case .chart, .stats:
            Button {
                shareSheetDismissed = false
                selection = format
                selectedCard = format == .chart ? .chart : .stats
            } label: {
                WorkoutShareCardPreview(snapshot: WorkoutShareSnapshot(record: record),
                                        style: format == .chart ? .chart : .stats, accent: accent)
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
        .disabled(pageDraft.isPreparingShare)
    }

    private var shareButton: some View {
        Button(action: shareSelectedFormat) {
            HStack(spacing: 10) {
                if pageDraft.isPreparingShare {
                    ProgressView().tint(isCardSelected ? accent.foregroundColor : .black)
                }
                Text(pageDraft.isPreparingShare ? pageDraft.uploadStatusText : currentFormat.action)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(isCardSelected ? accent.foregroundColor : .black)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isCardSelected ? accent.color : .white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shareSelectedWorkoutFormat")
        .disabled(pageDraft.isPreparingShare)
    }

    private var shareActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            shareButton
            if isCardSelected {
                Button {
                    shareSheetDismissed = false
                    selectedCard = currentFormat == .chart ? .chart : .stats
                } label: {
                    Text("Customize")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("customizeWorkoutCard")
                .accessibilityHint("Edit this card’s accent, title and range")
                .disabled(pageDraft.isPreparingShare)
            }
        }
    }

    private func analyticsContext(for format: ShareFormat) -> ShareAnalyticsContext {
        ShareAnalyticsContext(source: source, format: format.analyticsFormat)
    }

    private func shareSelectedFormat() {
        shareSheetDismissed = false
        switch currentFormat {
        case .chart: shareCard(style: .chart)
        case .stats: shareCard(style: .stats)
        case .text:
            pageDraft.prepareShare { url in
                let analytics = ShareAnalyticsSession(context: analyticsContext(for: .text))
                var text = record.summaryText()
                if let url { text += "\n\nView full workout: \(url.absoluteString)" }
                sharePayload = SharePayload(items: [text], subject: "Workout Summary", analytics: analytics)
            }
        case .logs:
            pageDraft.prepareShare { url in
                let analytics = ShareAnalyticsSession(context: analyticsContext(for: .logs))
                do {
                    let file = try JSONLogFile.create(json: record.jsonString(), prefix: "BPM-workout", date: record.startAt)
                    var items: [Any] = [file]
                    if let url { items.append("View full workout: \(url.absoluteString)") }
                    sharePayload = SharePayload(items: items, subject: "Workout Logs (JSON)", analytics: analytics)
                } catch {
                    analytics.finish(completed: false, failed: true)
                    exportError = "The JSON file couldn’t be created. Please try again."
                }
            }
        }
    }

    private func shareCard(style: WorkoutShareStyle) {
        let snapshot = WorkoutShareSnapshot(record: record)
        let analytics = ShareAnalyticsSession(context: analyticsContext(for: currentFormat))
        guard let image = WorkoutShareCardRenderer.image(snapshot: snapshot, style: style, accent: accent) else {
            analytics.finish(completed: false, failed: true)
            exportError = "The card couldn’t be created. Please try again."
            return
        }
        do {
            let item = try WorkoutShareImageItem(image: image, title: snapshot.title)
            pageDraft.prepareShare { url in
                let items: [Any]
                if let url {
                    items = [WorkoutShareLinkItem(url: url, title: snapshot.title, imageFileURL: item.fileURL)]
                } else {
                    items = [item]
                }
                sharePayload = SharePayload(items: items, subject: snapshot.title, analytics: analytics)
            }
        } catch {
            analytics.finish(completed: false, failed: true)
            exportError = "The card couldn’t be created. Please try again."
        }
    }
}

#if DEBUG
#Preview {
    WorkoutShareDrawer(record: WorkoutSharePreviewFixture.record, source: .workoutDetail)
}
#endif
