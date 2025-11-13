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
                HStack(spacing: 6) {
                    if context.state.isSharing {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 14))
                            .foregroundColor(context.state.isViewing ? .green : .white)
                    }
                    Text("\(context.state.bpm)")
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                }
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
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
                if content.isSharing {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28))
                        .foregroundColor(content.isViewing ? .green : .white)
                }
                
                // BPM number and label
                HStack(alignment: .center, spacing: 8) {
                    Text("\(content.bpm)")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                    Text("BPM")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
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
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
        }
    }
}
