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
                    HeartRateLiveActivityView(content: context.state, isStale: context.isStale)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                }
            } compactLeading: {
                let textColor: Color = {
                    if context.state.hasError {
                        return .red
                    } else if context.state.isSharing || context.state.isViewing {
                        return .green
                    }
                    return .white
                }()

                Text(context.isStale ? "--" : (context.state.bpm.map { "\($0)" } ?? "--"))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                .foregroundColor(textColor)
            } compactTrailing: {
                if let elapsed = context.state.elapsedSeconds {
                    WorkoutElapsedText(content: context.state, elapsed: elapsed, width: 80, alignment: .trailing)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                }
            } minimal: {
                let textColor: Color = {
                    if context.state.hasError {
                        return .red
                    } else if context.state.isSharing || context.state.isViewing {
                        return .green
                    }
                    return .white
                }()

                Text(context.isStale ? "--" : (context.state.bpm.map { "\($0)" } ?? "--"))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                .foregroundColor(textColor)
            }
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

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Big BPM on the left with icon and label
            HStack(alignment: .center, spacing: 12) {
                // Icon - middle aligned to left of BPM number
                if content.hasError {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                } else if content.isSharing {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28))
                        .foregroundColor(content.isViewing ? .green : .white)
                }

                // BPM number (show "--" when disconnected)
                Text(isStale ? "--" : (content.bpm.map { "\($0)" } ?? "--"))
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
            }
            .layoutPriority(0)

            Spacer(minLength: 12)

            // Stats on the right, horizontal
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
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Zone")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
            Text(zone.name)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
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
        // Widget timers are horizontally flexible. An explicit width keeps the
        // island compact and gives the fixed-size stats row a finite ideal width.
        // Reserve room for hours so suspension and pause do not change the layout.
        .frame(width: width, alignment: alignment)
    }
}
