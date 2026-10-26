import SwiftUI

/// A fresh draft for one image. Closing the editor discards its title and range overrides.
struct WorkoutShareCardEditor: View {
    let record: WorkoutRecord
    let style: WorkoutShareStyle
    @State private var range: WorkoutShareRange
    @State private var cardTitle: String
    @State private var sharePayload: SharePayload?
    @State private var renderFailed = false
    @FocusState private var isTitleFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesInlineShareButton: Bool {
        verticalSizeClass == .compact && dynamicTypeSize.isAccessibilitySize
    }

    init(record: WorkoutRecord, style: WorkoutShareStyle) {
        self.record = record
        self.style = style
        _range = State(initialValue: .full(record.durationSeconds))
        _cardTitle = State(initialValue: WorkoutShareSnapshot(record: record).title)
    }

    var body: some View {
        let snapshot = WorkoutShareSnapshot(record: record, range: range, titleOverride: cardTitle)
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    // Keyboard height must not switch layouts while the title field has focus.
                    let landscape = verticalSizeClass == .compact || geometry.size.width >= 700
                    let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                        : AnyLayout(VStackLayout(spacing: 18))
                    layout {
                        WorkoutShareCardPreview(snapshot: snapshot, style: style)
                            .frame(maxWidth: min(300, max(200, geometry.size.height * (landscape ? 0.95 : 0.58) / 1.25)))
                            .accessibilityIdentifier("workoutSharePreview")

                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Card title").font(.subheadline)
                                TextField("Workout", text: $cardTitle)
                                    .textFieldStyle(.roundedBorder)
                                    .submitLabel(.done)
                                    .focused($isTitleFocused)
                                    .onSubmit { isTitleFocused = false }
                                    .accessibilityIdentifier("workoutCardTitleField")
                            }

                            WorkoutRangeSelector(record: record, range: $range)
                                .disabled(record.durationSeconds <= 1)

                            Text("Changes apply only to this share card.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if style == .stats && !snapshot.isFullWorkout && record.zoneConfig == nil {
                                Text("For this older workout, Top Zone uses your current zone settings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if usesInlineShareButton && !isTitleFocused {
                                shareButton(snapshot: snapshot)
                            }
                        }
                        .frame(maxWidth: landscape ? 460 : .infinity)
                    }
                    .padding(16)
                    .frame(maxWidth: landscape ? 900 : 500)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("workoutCardEditorScroll")
            }
            .safeAreaInset(edge: .bottom) {
                if !isTitleFocused && !usesInlineShareButton {
                    shareButton(snapshot: snapshot)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
            }
            .navigationTitle("\(style.rawValue) Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        isTitleFocused = false
                        range = .full(record.durationSeconds)
                        cardTitle = WorkoutShareSnapshot(record: record).title
                    }
                    .disabled(snapshot.isFullWorkout && cardTitle == WorkoutShareSnapshot(record: record).title)
                    .accessibilityIdentifier("resetWorkoutCard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("closeWorkoutCardEditor")
                }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items, subject: payload.subject)
            }
            .alert("Couldn’t Create Image", isPresented: $renderFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try sharing the card again.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    private func shareButton(snapshot: WorkoutShareSnapshot) -> some View {
        Button {
            guard let image = WorkoutShareCardRenderer.image(snapshot: snapshot, style: style) else {
                renderFailed = true
                return
            }
            do {
                let item = try WorkoutShareImageItem(image: image, title: snapshot.title)
                sharePayload = SharePayload(items: [item], subject: snapshot.title)
            } catch {
                renderFailed = true
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 1, green: 0.39, blue: 0.34))
        .foregroundStyle(.black)
        .controlSize(.large)
        .accessibilityIdentifier("shareWorkoutImage")
    }

}

private struct WorkoutRangeSelector: View {
    let record: WorkoutRecord
    @Binding var range: WorkoutShareRange

    private var total: TimeInterval { max(1, record.durationSeconds) }
    private var minimumSpan: TimeInterval { min(1, total) }

    var body: some View {
        VStack(spacing: 12) {
            rangeSlider(title: "Start", value: Binding(
                get: { range.start },
                set: { range = WorkoutShareRange(start: min($0, range.end - minimumSpan), end: range.end, duration: total) }
            ), valueText: WorkoutShareSnapshot.time(range.start), identifier: "workoutRangeStart")
            rangeSlider(title: "End", value: Binding(
                get: { range.end },
                set: { range = WorkoutShareRange(start: range.start, end: max($0, range.start + minimumSpan), duration: total) }
            ), valueText: WorkoutShareSnapshot.time(range.end), identifier: "workoutRangeEnd")
            HStack {
                Text("Selected duration")
                Spacer()
                Text(WorkoutShareSnapshot.time(range.duration)).monospacedDigit()
                    .accessibilityIdentifier("selectedWorkoutDuration")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func rangeSlider(title: String, value: Binding<Double>, valueText: String, identifier: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit()
            }
            .font(.subheadline)
            // Round the selection without a step parameter, which adds a second tick track.
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }),
                   in: 0...total) { Text(title) }
                .tint(Color(red: 1, green: 0.39, blue: 0.34))
                .accessibilityValue(valueText)
                .accessibilityIdentifier(identifier)
        }
    }
}
