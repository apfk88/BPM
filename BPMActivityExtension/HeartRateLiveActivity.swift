import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.1, *)
struct HeartRateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeartRateActivityAttributes.self) { context in
            HeartRateLiveActivityView(content: context.state, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HeartRateLiveActivityView(content: context.state, isStale: context.isStale, isExpanded: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }
            } compactLeading: {
                IslandLeadingValue(content: context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandTrailingValue(content: context.state, isStale: context.isStale)
            } minimal: {
                IslandLeadingValue(content: context.state, isStale: context.isStale, isMinimal: true)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private extension HeartRateActivityAttributes.ContentState {
    func showsWorkoutTimer(isStale: Bool) -> Bool {
        elapsedSeconds != nil && (isStale || (bpm ?? 0) <= 0)
    }

    var readingColor: Color {
        if hasError { return .red }
        return isSharing || isViewing ? .green : .white
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct IslandLeadingValue: View {
    @Environment(\.self) private var environment
    let content: HeartRateActivityAttributes.ContentState
    let isStale: Bool
    var isMinimal = false

    private var isWidthLimited: Bool {
        if #available(iOSApplicationExtension 27.0, *) {
            return environment.isDynamicIslandLimitedInWidth
        }
        return false
    }

    private var usesSmallLayout: Bool { isMinimal || isWidthLimited }

    var body: some View {
        Group {
            if content.showsWorkoutTimer(isStale: isStale) {
                Image(systemName: "stopwatch")
                    .accessibilityLabel("Workout timer active")
            } else {
                Text(isStale ? "--" : (content.bpm.map { "\($0)" } ?? "--"))
                    .accessibilityLabel(isStale ? "Heart rate unavailable" : (content.bpm.map { "\($0) beats per minute" } ?? "Heart rate unavailable"))
            }
        }
        // iOS 27 also constrains compact views when another Live Activity is
        // present. The small layout fits inside Apple's 28-point safe circle.
        .font(.system(size: usesSmallLayout ? 13 : 18, weight: .bold, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .allowsTightening(true)
        .padding(.horizontal, 2)
        .frame(maxWidth: usesSmallLayout ? 26 : 38, maxHeight: usesSmallLayout ? 18 : 22)
        .foregroundColor(content.showsWorkoutTimer(isStale: isStale) ? .white : content.readingColor)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct IslandTrailingValue: View {
    @Environment(\.self) private var environment
    let content: HeartRateActivityAttributes.ContentState
    let isStale: Bool

    private var isWidthLimited: Bool {
        if #available(iOSApplicationExtension 27.0, *) {
            return environment.isDynamicIslandLimitedInWidth
        }
        return false
    }

    var body: some View {
        // A full elapsed time cannot fit in a 28-point circle. The leading
        // stopwatch identifies timer-only workouts in the constrained layout.
        if !isWidthLimited, content.showsWorkoutTimer(isStale: isStale), let elapsed = content.elapsedSeconds {
            WorkoutElapsedText(content: content, elapsed: elapsed, width: 50, alignment: .trailing)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
    }
}

private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainingSeconds = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

@available(iOSApplicationExtension 16.1, *)
private struct HeartRateLiveActivityView: View {
    let content: HeartRateActivityAttributes.ContentState
    let isStale: Bool
    var isExpanded = false

    var body: some View {
        Group {
            if content.showsWorkoutTimer(isStale: isStale), let elapsed = content.elapsedSeconds {
                VStack(alignment: isExpanded ? .center : .leading, spacing: 6) {
                    Label("Workout", systemImage: "stopwatch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    WorkoutElapsedText(content: content, elapsed: elapsed, width: 220, alignment: isExpanded ? .center : .leading)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: isExpanded ? .center : .leading)
            } else if isExpanded {
                // One stable arrangement uses the whole Island without exceeding
                // its height limit: centered reading, then a single-line footer.
                VStack(spacing: 10) {
                    heartRate
                        .frame(maxWidth: .infinity)
                    expandedFooter
                }
            } else {
                // The Lock Screen can use a wider row, with an inline fallback.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 0) {
                        heartRate
                        Spacer(minLength: 20)
                        stats
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        heartRate
                        inlineStats
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heartRate: some View {
        HStack(alignment: .center, spacing: isExpanded ? 8 : 12) {
            if content.hasError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: isExpanded ? 20 : 28))
                    .foregroundColor(.red)
            } else if content.isSharing {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: isExpanded ? 20 : 28))
                    .foregroundColor(.green)
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: isExpanded ? 20 : 28))
                    .foregroundColor(content.isViewing ? .green : .white)
            }

            // BPM number (show "--" when disconnected)
            ZStack(alignment: isExpanded ? .center : .leading) {
                // Keep the layout stable when a reading crosses 100 BPM.
                Text("888")
                    .hidden()
                    .accessibilityHidden(true)
                Text(isStale ? "--" : (content.bpm.map { "\($0)" } ?? "--"))
            }
            .font(.system(size: isExpanded ? 52 : 56, weight: .bold, design: .monospaced))
            .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var expandedFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let elapsed = content.elapsedSeconds {
                HStack(spacing: 6) {
                    inlineLabel("Time")
                    WorkoutElapsedText(content: content, elapsed: elapsed, width: 90)
                        .minimumScaleFactor(0.6)
                }
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if let maximum = content.maximum {
                    expandedStat("Max", value: maximum)
                }
                if let average = content.average {
                    expandedStat("Avg", value: average)
                }
            }
            if !isStale, let zone = content.zone {
                ZoneValue(zone: zone, inline: true)
                    .frame(maxWidth: .infinity, alignment: content.elapsedSeconds == nil ? .center : .trailing)
            }
        }
        .font(.system(size: 18, weight: .bold, design: .monospaced))
        .lineLimit(1)
    }

    private func expandedStat(_ title: String, value: Int) -> some View {
        HStack(spacing: 6) {
            inlineLabel(title)
            Text("\(value)")
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private var stats: some View {
        HStack(spacing: 16) {
            if let elapsed = content.elapsedSeconds {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Time").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    WorkoutElapsedText(content: content, elapsed: elapsed, width: 110)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            } else {
                if let max = content.maximum {
                    StatValue(label: "Max", value: max)
                }
                if let avg = content.average {
                    StatValue(label: "Avg", value: avg)
                }
            }
            if !isStale, let zone = content.zone {
                ZoneValue(zone: zone)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var inlineStats: some View {
        // Expanded Live Activities also have a height limit. Keep the fallback
        // stats on one line so their values remain inside the system container.
        HStack(spacing: 16) {
            if let elapsed = content.elapsedSeconds {
                HStack(spacing: 6) {
                    inlineLabel("Time")
                    WorkoutElapsedText(content: content, elapsed: elapsed, width: 90)
                }
            } else {
                if let maximum = content.maximum {
                    HStack(spacing: 6) {
                        inlineLabel("Max")
                        Text("\(maximum)")
                    }
                }
                if let average = content.average {
                    HStack(spacing: 6) {
                        inlineLabel("Avg")
                        Text("\(average)")
                    }
                }
            }
            if !isStale, let zone = content.zone {
                ZoneValue(zone: zone, inline: true)
            }
        }
        .font(.system(size: 18, weight: .bold, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func inlineLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct StatValue: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct StatTextValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct ZoneValue: View {
    let zone: ZoneInfo
    var inline = false

    private var zoneColor: Color {
        switch zone.colorName {
        case "gray": return .gray
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        default: return .white
        }
    }

    var body: some View {
        let layout = inline
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            Text("Zone")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
            Text(zone.name)
                .font(.system(size: inline ? 18 : 22, weight: .bold, design: .monospaced))
                .foregroundColor(zoneColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct WorkoutElapsedText: View {
    let content: HeartRateActivityAttributes.ContentState
    let elapsed: Int
    let width: CGFloat
    var alignment: Alignment = .leading

    var body: some View {
        Group {
            if let reference = content.timerReferenceDate {
                // System-rendered time keeps moving while the app is suspended and
                // stops at the planned end of a preset or cooldown.
                Text(timerInterval: reference...max(reference, content.timerEndDate ?? .distantFuture), countsDown: false)
                    .monospacedDigit()
            } else {
                Text(formatDuration(elapsed))
            }
        }
        // Widget timers are horizontally flexible. An explicit width gives the
        // expanded and Lock Screen stats row a finite ideal width.
        // Reserve room for hours so suspension and pause do not change the layout.
        .frame(width: width, alignment: alignment)
    }
}

#Preview("Expanded workout", as: .dynamicIsland(.expanded), using: HeartRateActivityAttributes(title: "Current BPM")) {
    HeartRateLiveActivity()
} contentStates: {
    HeartRateActivityAttributes.ContentState(
        bpm: 188, average: 145, maximum: 188, minimum: 90,
        elapsedSeconds: 3661, timerReferenceDate: Date().addingTimeInterval(-3661), zone: .zone4
    )
    HeartRateActivityAttributes.ContentState(
        bpm: 220, average: 145, maximum: 220, minimum: 90,
        elapsedSeconds: 3661, zone: .zone5
    )
    HeartRateActivityAttributes.ContentState(
        bpm: nil, average: 145, maximum: 188, minimum: 90,
        elapsedSeconds: 3661, hasError: true
    )
}

#Preview("Narrow layouts", traits: .sizeThatFitsLayout) {
    VStack(spacing: 20) {
        HeartRateLiveActivityView(
            content: .init(bpm: 220, average: 145, maximum: 220, minimum: 90,
                           elapsedSeconds: 3661, zone: .zone5),
            isStale: false
        )
        HeartRateLiveActivityView(
            content: .init(bpm: 188, average: 145, maximum: 188, minimum: 90, zone: .zone4),
            isStale: false
        )
    }
    .frame(width: 240)
    .padding()
    .background(.black)
    .preferredColorScheme(.dark)
}

#Preview("Narrow expanded layouts", traits: .sizeThatFitsLayout) {
    VStack(spacing: 24) {
        HeartRateLiveActivityView(
            content: .init(bpm: 188, average: 145, maximum: 188, minimum: 90,
                           elapsedSeconds: 3661, zone: .zone4),
            isStale: false,
            isExpanded: true
        )
        HeartRateLiveActivityView(
            content: .init(bpm: 220, average: 145, maximum: 220, minimum: 90, zone: .zone5),
            isStale: false,
            isExpanded: true
        )
        HeartRateLiveActivityView(
            content: .init(bpm: nil, average: 145, maximum: 188, minimum: 90,
                           elapsedSeconds: 3661, hasError: true),
            isStale: false,
            isExpanded: true
        )
    }
    .frame(width: 240)
    .padding()
    .background(.black)
    .preferredColorScheme(.dark)
}


#Preview("Compact readings", as: .dynamicIsland(.compact), using: HeartRateActivityAttributes(title: "Current BPM")) {
    HeartRateLiveActivity()
} contentStates: {
    HeartRateActivityAttributes.ContentState(bpm: 88, average: nil, maximum: nil, minimum: nil)
    HeartRateActivityAttributes.ContentState(bpm: 188, average: nil, maximum: nil, minimum: nil, isSharing: true)
    HeartRateActivityAttributes.ContentState(bpm: 220, average: nil, maximum: nil, minimum: nil, isViewing: true)
    HeartRateActivityAttributes.ContentState(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                            elapsedSeconds: 3661, timerReferenceDate: Date().addingTimeInterval(-3661))
}

#Preview("Minimal readings", as: .dynamicIsland(.minimal), using: HeartRateActivityAttributes(title: "Current BPM")) {
    HeartRateLiveActivity()
} contentStates: {
    HeartRateActivityAttributes.ContentState(bpm: 88, average: nil, maximum: nil, minimum: nil)
    HeartRateActivityAttributes.ContentState(bpm: 188, average: nil, maximum: nil, minimum: nil, isSharing: true)
    HeartRateActivityAttributes.ContentState(bpm: 220, average: nil, maximum: nil, minimum: nil, isViewing: true)
    HeartRateActivityAttributes.ContentState(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                            elapsedSeconds: 3661, timerReferenceDate: Date().addingTimeInterval(-3661))
}

#Preview("28-point Island safe area", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        ForEach([88, 188, 220], id: \.self) { bpm in
            IslandLeadingValue(
                content: .init(bpm: bpm, average: nil, maximum: nil, minimum: nil),
                isStale: false,
                isMinimal: true
            )
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(.gray))
        }
        IslandLeadingValue(
            content: .init(bpm: nil, average: nil, maximum: nil, minimum: nil, elapsedSeconds: 3661),
            isStale: false,
            isMinimal: true
        )
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(.gray))
    }
    .padding()
    .background(.black)
    .preferredColorScheme(.dark)
}
