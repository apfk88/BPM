import SwiftUI

struct HeartRateChartViewport {
    let totalDuration: TimeInterval

    init(totalDuration: TimeInterval) {
        self.totalDuration = max(totalDuration, 1)
    }

    var minimumVisibleDuration: TimeInterval {
        min(totalDuration, max(10, min(60, totalDuration / 10)))
    }

    func visibleDuration(
        startingAt startingDuration: TimeInterval,
        magnification: Double
    ) -> TimeInterval {
        let safeMagnification = max(magnification, 0.01)
        return min(
            totalDuration,
            max(minimumVisibleDuration, startingDuration / safeMagnification)
        )
    }

    func clampedScrollPosition(
        _ position: TimeInterval,
        visibleDuration: TimeInterval
    ) -> TimeInterval {
        max(0, min(position, totalDuration - visibleDuration))
    }
}

struct ExpandedHeartRateChartView: View {
    @Environment(\.dismiss) private var dismiss

    let record: WorkoutRecord

    @State private var selectedTime: TimeInterval?
    @State private var isInspecting = false
    @State private var visibleDuration: TimeInterval
    @State private var scrollPosition: TimeInterval = 0
    @State private var zoomStartDuration: TimeInterval?

    private let viewport: HeartRateChartViewport

    init(record: WorkoutRecord) {
        self.record = record
        let viewport = HeartRateChartViewport(totalDuration: record.chartMaxTime)
        self.viewport = viewport
        self._visibleDuration = State(initialValue: viewport.totalDuration)
    }

    var body: some View {
        GeometryReader { geometry in
            landscapeContent
                .frame(width: geometry.size.height, height: geometry.size.width)
                .rotationEffect(.degrees(90))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private var landscapeContent: some View {
        VStack(spacing: 12) {
            header

            HeartRateTimelineChart(
                dataPoints: record.chartDataPoints,
                segments: record.chartSegments,
                maxTime: viewport.totalDuration,
                allowsHorizontalScrolling: true,
                selectedTime: $selectedTime,
                isDragging: $isInspecting,
                visibleDuration: $visibleDuration,
                scrollPosition: $scrollPosition
            )
            .simultaneousGesture(magnifyGesture)
            .accessibilityHint("Pinch to zoom, drag to pan, or tap to inspect heart rate")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color.black)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workoutTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(record.startAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Label("Pinch to zoom • Drag to pan", systemImage: "hand.pinch")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(zoomLabel)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            HStack(spacing: 10) {
                chartControl(
                    systemImage: "minus.magnifyingglass",
                    accessibilityLabel: "Zoom out",
                    isDisabled: visibleDuration >= viewport.totalDuration
                ) {
                    adjustZoom(by: 0.5)
                }

                chartControl(
                    systemImage: "arrow.counterclockwise",
                    accessibilityLabel: "Reset zoom",
                    isDisabled: visibleDuration >= viewport.totalDuration && scrollPosition == 0
                ) {
                    resetViewport()
                }

                chartControl(
                    systemImage: "plus.magnifyingglass",
                    accessibilityLabel: "Zoom in",
                    isDisabled: visibleDuration <= viewport.minimumVisibleDuration
                ) {
                    adjustZoom(by: 2)
                }

                chartControl(
                    systemImage: "xmark.circle.fill",
                    accessibilityLabel: "Close chart"
                ) {
                    dismiss()
                }
            }
        }
    }

    private func chartControl(
        systemImage: String,
        accessibilityLabel: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isDisabled ? .gray.opacity(0.45) : .white)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if zoomStartDuration == nil {
                    zoomStartDuration = visibleDuration
                }
                guard let zoomStartDuration else { return }
                updateVisibleDuration(
                    viewport.visibleDuration(
                        startingAt: zoomStartDuration,
                        magnification: Double(value.magnification)
                    )
                )
            }
            .onEnded { _ in
                zoomStartDuration = nil
            }
    }

    private func adjustZoom(by magnification: Double) {
        withAnimation(.easeInOut(duration: 0.2)) {
            updateVisibleDuration(
                viewport.visibleDuration(
                    startingAt: visibleDuration,
                    magnification: magnification
                )
            )
        }
    }

    private func updateVisibleDuration(_ duration: TimeInterval) {
        visibleDuration = duration
        scrollPosition = viewport.clampedScrollPosition(
            scrollPosition,
            visibleDuration: duration
        )
    }

    private func resetViewport() {
        withAnimation(.easeInOut(duration: 0.2)) {
            visibleDuration = viewport.totalDuration
            scrollPosition = 0
            selectedTime = nil
        }
    }

    private var workoutTitle: String {
        let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return "Heart Rate" }
        return title
    }

    private var zoomLabel: String {
        let zoom = viewport.totalDuration / visibleDuration
        return String(format: "%.1f×", zoom)
    }
}
