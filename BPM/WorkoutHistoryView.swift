import SwiftUI

struct WorkoutHistoryView: View {
    @ObservedObject var store: WorkoutStore
    @State private var selectedWorkoutID: UUID?
    @State private var sharePayload: SharePayload?
    @State private var shareError: String?
    @ObservedObject private var pageService: WorkoutPageService
    @State private var workoutPendingDeletion: WorkoutRecord?
    @State private var deletionError: String?
    @State private var deletingPage = false

    init(store: WorkoutStore, pageService: WorkoutPageService? = nil) {
        self.store = store
        self.pageService = pageService ?? .shared
    }

    var body: some View {
        List {
            if !store.workouts.isEmpty {
                ForEach(store.workouts) { workout in
                    Button {
                        selectedWorkoutID = workout.id
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            WorkoutShareCardPreview(snapshot: WorkoutShareSnapshot(record: workout), style: .chart, compact: true)
                            if let status = pageStatus(for: workout.id) {
                                Label(status.title, systemImage: status.icon)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.white.opacity(0.08), in: Capsule())
                                    .accessibilityIdentifier("workoutPrivateLinkBadge")
                            }
                        }
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("savedWorkoutHistoryRow")
                    .accessibilityValue(pageStatus(for: workout.id)?.title ?? "")
                    .accessibilityHint("Opens workout details")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if pageService.entry(for: workout.id) != nil {
                                workoutPendingDeletion = workout
                            } else {
                                store.deleteWorkout(workout)
                            }
                        } label: {
                            Text("Delete")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .overlay {
            if store.workouts.isEmpty {
                ContentUnavailableView("No workouts yet", systemImage: "waveform.path.ecg",
                                       description: Text("Saved workouts will appear here."))
            }
        }
        .navigationTitle("Workout History")
        .analyticsScreen(.workoutHistory)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !pageService.entries.isEmpty, !pageService.isWorking else { return }
            // Keep cached controls available offline while reconciling links
            // replaced or removed from another recovered installation.
            try? await pageService.refresh()
        }
        .navigationDestination(item: $selectedWorkoutID) { workoutID in
            if let workout = store.workouts.first(where: { $0.id == workoutID }) {
                WorkoutDetailView(
                    initialRecord: workout,
                    store: store,
                    pageService: pageService,
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
                .accessibilityLabel("Export workout history")
                .disabled(store.workouts.isEmpty)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(payload: payload)
        }
        .confirmationDialog("Delete workout?", isPresented: Binding(
            get: { workoutPendingDeletion != nil },
            set: { if !$0 { workoutPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let workout = workoutPendingDeletion {
                Button("Delete Workout Only", role: .destructive) { store.deleteWorkout(workout) }
                Button("Delete Workout and Shared Pages", role: .destructive) {
                    deleteWorkoutAndPage(workout)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This workout has shared pages. You can keep them online and manage them later in Shared Pages.")
        }
        .disabled(deletingPage)
        .alert("Couldn’t Delete Shared Page", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(deletionError ?? "The workout has been kept. Please try again.") }
        .alert("Couldn’t Export Logs", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "Please try again.")
        }
    }

    private func pageStatus(for workoutID: UUID) -> (title: String, icon: String)? {
        let pages = pageService.entries.filter { $0.localWorkoutID == workoutID }
        guard !pages.isEmpty else { return nil }
        if pages.contains(where: { $0.status == .published && !$0.hasPendingDeletion }) {
            return ("Private link", "link")
        }
        if pages.contains(where: \.hasPendingDeletion) {
            return ("Deletion pending", "clock")
        }
        return ("Link pending", "clock")
    }

    private func presentLogs(json: String, prefix: String, date: Date, subject: String) {
        let analytics = ShareAnalyticsSession(context: ShareAnalyticsContext(source: .workoutHistory, format: .logs))
        do {
            let file = try JSONLogFile.create(json: json, prefix: prefix, date: date)
            sharePayload = SharePayload(items: [file], subject: subject, analytics: analytics)
        } catch {
            analytics.finish(completed: false, failed: true)
            shareError = "The JSON file couldn’t be created. Please try again."
        }
    }

    private func deleteWorkoutAndPage(_ workout: WorkoutRecord) {
        deletingPage = true
        Task {
            defer { deletingPage = false }
            do {
                for entry in pageService.entries.filter({ $0.localWorkoutID == workout.id }) {
                    try await pageService.delete(entry)
                }
                store.deleteWorkout(workout)
            } catch { deletionError = error.localizedDescription }
        }
    }

}

struct WorkoutDetailView: View {
    let initialRecord: WorkoutRecord
    @ObservedObject var store: WorkoutStore
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDeleteAlert = false
    @State private var showExpandedHeartRateChart = false
    @State private var isEditingWorkout = false
    @State private var isSharingWorkout = false
    @ObservedObject private var pageService: WorkoutPageService
    @State private var deletionError: String?
    @State private var deletingPage = false

    init(initialRecord: WorkoutRecord, store: WorkoutStore, pageService: WorkoutPageService? = nil,
         onDelete: @escaping () -> Void) {
        self.initialRecord = initialRecord
        self.store = store
        self.pageService = pageService ?? .shared
        self.onDelete = onDelete
    }

    private var record: WorkoutRecord {
        store.workouts.first(where: { $0.id == initialRecord.id }) ?? initialRecord
    }

    var body: some View {
        workoutLog
        .navigationTitle("Workout")
        .analyticsScreen(.workoutDetail)
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
            WorkoutShareDrawer(record: record, source: .workoutDetail, pageService: pageService)
        }
        .fullScreenCover(isPresented: $showExpandedHeartRateChart) {
            ExpandedHeartRateChartView(record: record)
        }
        .alert("Delete Workout?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button(pageService.entry(for: record.id) == nil ? "Delete" : "Delete Workout Only", role: .destructive) {
                onDelete()
                dismiss()
            }
            if pageService.entry(for: record.id) != nil {
                Button("Delete Workout and Shared Pages", role: .destructive) {
                    deletingPage = true
                    Task {
                        defer { deletingPage = false }
                        do {
                            for entry in pageService.entries.filter({ $0.localWorkoutID == record.id }) {
                                try await pageService.delete(entry)
                            }
                            onDelete()
                            dismiss()
                        } catch { deletionError = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text(pageService.entry(for: record.id) == nil
                 ? "This will permanently remove the workout from history."
                 : "This workout has shared pages. You can keep them online and manage them later in Shared Pages.")
        }
        .disabled(deletingPage)
        .alert("Couldn’t Delete Shared Page", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(deletionError ?? "The workout has been kept. Please try again.") }
    }

    private var workoutLog: some View {
        let snapshot = WorkoutShareSnapshot(record: record)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview(snapshot: snapshot)

                let pages = pageService.entries.filter { $0.localWorkoutID == record.id }
                if !pages.isEmpty {
                    logSection("Private link") {
                        ForEach(pages) { entry in
                            WorkoutSavedPageLink(entry: entry, service: pageService)
                            if entry.id != pages.last?.id { rule }
                        }
                    }
                }

                if let notes = normalizedNotes {
                    logSection("Description") {
                        Text(notes)
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if !record.zones.isEmpty {
                    zonesSection
                }
                if !record.sets.isEmpty {
                    setsSection
                }
                detailsSection

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete Workout", systemImage: "trash")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.top, 4)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .accessibilityIdentifier("workoutLogTab")
    }

    private func overview(snapshot: WorkoutShareSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.title)
                    .font(.title.weight(.semibold))
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(record.startAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(WorkoutCardPalette.muted)
            }

            if snapshot.points.isEmpty {
                Label("No heart rate samples saved", systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(WorkoutCardPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Button {
                    showExpandedHeartRateChart = true
                } label: {
                    VStack(spacing: 18) {
                        HStack {
                            Text("Heart rate")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(WorkoutCardPalette.muted)
                        WorkoutSharePlot(snapshot: snapshot)
                            .frame(height: 180)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand heart rate chart")
                .accessibilityHint("Opens a full-screen chart with zoom and pan controls")
            }

            VStack(spacing: 20) {
                rule
                headlineMetrics(snapshot: snapshot)
            }
        }
        .padding(24)
        .background {
            ZStack(alignment: .topTrailing) {
                WorkoutCardPalette.background
                RadialGradient(colors: [.white.opacity(0.13), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 320)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func headlineMetrics(snapshot: WorkoutShareSnapshot) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            headlineMetric(WorkoutShareSnapshot.time(snapshot.duration), label: "TOTAL TIME")
            headlineMetric(snapshot.average.map(String.init) ?? "—", label: "AVG BPM")
            headlineMetric(snapshot.maximum.map(String.init) ?? "—", label: "MAX BPM")
        }
    }

    private func headlineMetric(_ value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .medium))
                .monospacedDigit()
                .tracking(-0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(WorkoutCardPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    private var zonesSection: some View {
        let trackedTime = record.zones.reduce(0) { $0 + max(0, $1.duration) }
        return logSection("Time in zones") {
            VStack(spacing: 18) {
                ForEach(record.zones.sorted { $0.zone < $1.zone }) { zone in
                    VStack(spacing: 8) {
                        HStack {
                            Text("Zone \(zone.zone)")
                            Spacer()
                            Text(WorkoutShareSnapshot.time(zone.duration))
                                .monospacedDigit()
                                .foregroundStyle(WorkoutCardPalette.muted)
                        }
                        .font(.subheadline)
                        GeometryReader { geometry in
                            Capsule().fill(.white.opacity(0.08))
                            Capsule()
                                .fill(HeartRateZone(rawValue: zone.zone)?.color ?? .white)
                                .frame(width: geometry.size.width * (trackedTime > 0
                                    ? min(1, max(0, zone.duration / trackedTime)) : 0))
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var setsSection: some View {
        logSection("Sets") {
            VStack(spacing: 16) {
                ForEach(Array(record.sets.enumerated()), id: \.element.id) { index, set in
                    if index > 0 { rule }
                    setRow(set)
                }
            }
        }
    }

    private func setRow(_ set: WorkoutSetSummary) -> some View {
        let isRecovery = set.isRestSet || set.isCooldownSet
        let hrLabel = isRecovery ? "Min" : "Max"
        let hrValue = isRecovery ? set.minBpm : set.maxBpm
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: set.isCooldownSet ? "snowflake" : set.isRestSet ? "pause.fill" : "play.fill")
                .font(.caption)
                .foregroundStyle(isRecovery ? WorkoutCardPalette.muted : .green)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(set.label)
                    .font(.subheadline.weight(.medium))
                Text("\(hrLabel) BPM \(hrValue.map(String.init) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(WorkoutCardPalette.muted)
            }
            Spacer(minLength: 8)
            Text(WorkoutShareSnapshot.time(set.setTime))
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsSection: some View {
        logSection("Details") {
            VStack(spacing: 16) {
                detailRow(label: "Min BPM", value: record.minHr.map(String.init))
                detailRow(label: "HRR (2 min)", value: record.hrr.map(String.init))
                if let calories = record.caloriesActive {
                    detailRow(label: "Active calories", value: "\(Int(round(calories))) kcal")
                }
                if let calories = record.caloriesTotal {
                    detailRow(label: "Calories", value: "\(Int(round(calories))) kcal")
                }
                rule
                detailRow(label: "Start", value: record.startAt.formatted(date: .abbreviated, time: .shortened))
                detailRow(label: "End", value: record.endAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func logSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(WorkoutCardPalette.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var rule: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private func detailRow(label: String, value: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).foregroundStyle(WorkoutCardPalette.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                Text(value ?? "—").monospacedDigit()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).foregroundStyle(WorkoutCardPalette.muted)
                Text(value ?? "—").monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var normalizedNotes: String? {
        let value = record.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

#Preview {
    WorkoutHistoryView(store: WorkoutStore())
}
