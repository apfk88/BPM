import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.1, *)
struct HeartRateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeartRateActivityAttributes.self) { context in
            HeartRateLiveActivityView(content: context.state)
                .padding()
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(context.state.bpm.map { "\($0)" } ?? "--")
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let max = context.state.maximum {
                            LabeledValue(title: "MAX", value: max)
                        }
                        if let min = context.state.minimum {
                            LabeledValue(title: "MIN", value: min)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let average = context.state.average {
                        Text("Avg \(average) • \(context.state.trendDescription)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
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

                Text(context.state.bpm.map { "\($0)" } ?? "--")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                let textColor: Color = {
                    if context.state.hasError {
                        return .red
                    } else if context.state.isSharing || context.state.isViewing {
                        return .green
                    }
                    return .white
                }()

                Text(context.state.bpm.map { "\($0)" } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct HeartRateLiveActivityView: View {
    let content: HeartRateActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
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
                Text(content.bpm.map { "\($0)" } ?? "--")
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer()

            // Stats on the right, horizontal
            HStack(spacing: 20) {
                if let max = content.maximum {
                    StatValue(label: "Max", value: max)
                }
                if let min = content.minimum {
                    StatValue(label: "Min", value: min)
                }
                if let avg = content.average {
                    StatValue(label: "Avg", value: avg)
                }
                if let zone = content.zone {
                    ZoneValue(zone: zone)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct LabeledValue: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline)
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct StatValue: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(zone.name)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(zoneColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
    }
}
