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
                        Text("\(context.state.bpm)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
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
                Text("\(context.state.bpm)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            } compactTrailing: {
                if let average = context.state.average {
                    Text("Avg\n\(average)")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .multilineTextAlignment(.trailing)
                }
            } minimal: {
                Text("\(context.state.bpm)")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
private struct HeartRateLiveActivityView: View {
    let content: HeartRateActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current BPM")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(content.bpm)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 8) {
                    if let average = content.average {
                        Text("Average \(average) • \(content.trendDescription)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let max = content.maximum {
                            LabeledValue(title: "MAX", value: max)
                        }
                        if let min = content.minimum {
                            LabeledValue(title: "MIN", value: min)
                        }
                    }
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
