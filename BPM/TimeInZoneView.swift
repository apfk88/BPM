//
//  TimeInZoneView.swift
//  BPM
//
//  Shows time spent in each heart rate zone during workout
//

import SwiftUI

struct TimeInZoneView: View {
    @ObservedObject var timerViewModel: TimerViewModel
    @ObservedObject var zoneStorage: HeartRateZoneStorage
    var isLandscape: Bool = false

    private var zoneData: [ZoneTimeData] {
        timerViewModel.timeInZones(config: zoneStorage.effectiveConfig)
    }

    private var totalTime: TimeInterval {
        zoneData.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isLandscape ? 6 : 10) {
            ForEach(HeartRateZone.allCases.reversed(), id: \.rawValue) { zone in
                let data = zoneData.first { $0.zone == zone } ?? ZoneTimeData(zone: zone, duration: 0)
                ZoneBarRow(
                    zone: zone,
                    duration: data.duration,
                    totalTime: totalTime,
                    isLandscape: isLandscape
                )
            }
        }
        .padding(.vertical, isLandscape ? 8 : 12)
    }
}

private struct ZoneBarRow: View {
    let zone: HeartRateZone
    let duration: TimeInterval
    let totalTime: TimeInterval
    let isLandscape: Bool

    private var percentage: Double {
        guard totalTime > 0 else { return 0 }
        return duration / totalTime
    }

    var body: some View {
        HStack(spacing: 8) {
            // Zone label
            Text(zone.displayName)
                .font(.system(size: isLandscape ? 12 : 14, weight: .bold, design: .monospaced))
                .foregroundColor(zone.color)
                .frame(width: isLandscape ? 24 : 28, alignment: .leading)

            // Bar chart
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: isLandscape ? 16 : 20)

                    // Filled portion
                    if percentage > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(zone.color)
                            .frame(width: max(4, geometry.size.width * percentage), height: isLandscape ? 16 : 20)
                    }
                }
            }
            .frame(height: isLandscape ? 16 : 20)

            // Duration text
            Text(formatDuration(duration))
                .font(.system(size: isLandscape ? 11 : 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: isLandscape ? 50 : 60, alignment: .trailing)
        }
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ZoneTimeData {
    let zone: HeartRateZone
    let duration: TimeInterval
}
