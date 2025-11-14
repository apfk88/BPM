//
//  HeartRateChartView.swift
//  BPM
//
//  Created for heart rate chart feature
//

import SwiftUI
import Charts

struct HeartRateChartView: View {
    @ObservedObject var timerViewModel: TimerViewModel
    @State private var selectedTime: TimeInterval?
    @State private var isDragging = false
    
    // Cache computed values to reduce recalculations
    private var dataPoints: [TimerViewModel.ChartDataPoint] {
        timerViewModel.chartDataPoints()
    }
    
    private var segments: [TimerViewModel.ChartSegment] {
        timerViewModel.chartSegments()
    }
    
    private var maxTime: TimeInterval {
        max(timerViewModel.chartMaxTime(), 1.0) // Ensure at least 1 second
    }
    
    private var yDomain: ClosedRange<Int> {
        yAxisDomain(for: dataPoints)
    }
    
    var body: some View {
        
        if dataPoints.isEmpty {
            // Empty state - show chart with axes but no data
            Chart {
                // Empty chart - no data points
            }
            .chartXScale(domain: 0...60) // Show 0-60 seconds as placeholder
            .chartYScale(domain: 60...180) // Show typical BPM range
            .chartXAxis {
                AxisMarks(position: .bottom, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.gray.opacity(0.3))
                    AxisValueLabel()
                        .foregroundStyle(.gray)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.gray.opacity(0.3))
                    AxisValueLabel()
                        .foregroundStyle(.gray)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .frame(minWidth: 0)
            }
            .padding(.leading, 8)
            .frame(height: 200)
            .overlay {
                // Overlay empty state message
                VStack(spacing: 8) {
                    Text("No workout data yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray.opacity(0.6))
                    
                    Text("Start your workout to see heart rate over time")
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
        } else {
            VStack(spacing: 0) {
                // Chart with segments
                Chart {
                    // Draw segment backgrounds first (so they appear behind the line)
                    // Skip work sets (no background), only show rest and cooldown
                    ForEach(segments.filter { $0.type != .work }) { segment in
                        RectangleMark(
                            xStart: .value("Start", segment.startTime),
                            xEnd: .value("End", segment.endTime),
                            yStart: .value("Min", yDomain.lowerBound),
                            yEnd: .value("Max", yDomain.upperBound)
                        )
                        .foregroundStyle(segmentColor(for: segment.type).opacity(0.2))
                    }
                    
                    // Draw vertical lines at set boundaries
                    ForEach(setBoundaries()) { boundary in
                        RuleMark(x: .value("Time", boundary.time))
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    
                    // Draw heart rate line
                    ForEach(dataPoints) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("BPM", point.bpm)
                        )
                        .foregroundStyle(.white)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    
                    // Draw selected point indicator if scrubbing
                    if let selectedTime = selectedTime,
                       let selectedPoint = dataPointAtTime(selectedTime, in: dataPoints) {
                        PointMark(
                            x: .value("Time", selectedPoint.time),
                            y: .value("BPM", selectedPoint.bpm)
                        )
                        .foregroundStyle(.white)
                        .symbolSize(100)
                    }
                }
                .chartXScale(domain: 0...maxTime)
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .automatic) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .frame(minWidth: 0)
                }
                .padding(.leading, 8) // Add padding to prevent left overflow
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .chartBackground { chartProxy in
                    // Invisible overlay for touch handling
                    GeometryReader { chartGeometry in
                        if let plotFrameAnchor = chartProxy.plotFrame {
                            let plotFrame = chartGeometry[plotFrameAnchor]
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            isDragging = true
                                            let location = value.location
                                            
                                            // Convert touch location to time value
                                            // Adjust location relative to plot area
                                            let relativeX = location.x - plotFrame.minX
                                            let normalizedX = relativeX / plotFrame.width
                                            let timeValue = normalizedX * maxTime
                                            
                                            selectedTime = max(0, min(timeValue, maxTime))
                                        }
                                        .onEnded { _ in
                                            isDragging = false
                                            // Keep selection visible briefly after drag ends
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                if !isDragging {
                                                    selectedTime = nil
                                                }
                                            }
                                        }
                                )
                        } else {
                            Rectangle()
                                .fill(Color.clear)
                        }
                    }
                }
                .frame(height: 200)
                
                // Selection info display
                if let selectedTime = selectedTime,
                   let selectedPoint = dataPointAtTime(selectedTime, in: dataPoints) {
                    HStack {
                        Text("Time: \(formatTime(selectedTime))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                        Spacer()
                        Text("BPM: \(selectedPoint.bpm)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
        }
    }
    
    private func segmentColor(for type: TimerViewModel.ChartSegment.SegmentType) -> Color {
        switch type {
        case .work:
            return .clear // Work sets have no background
        case .rest:
            return .green // Rest sets are green
        case .cooldown:
            return .blue // Cooldown sets are blue
        }
    }
    
    private func yAxisDomain(for dataPoints: [TimerViewModel.ChartDataPoint]) -> ClosedRange<Int> {
        guard !dataPoints.isEmpty else {
            return 0...200
        }
        
        let minBPM = dataPoints.map { $0.bpm }.min() ?? 0
        let maxBPM = dataPoints.map { $0.bpm }.max() ?? 200
        
        // Add padding (10% on each side, minimum 10 BPM)
        let range = Double(maxBPM - minBPM)
        let padding = max(range * 0.1, 10.0)
        
        let lowerBound = max(0, Int((Double(minBPM) - padding).rounded()))
        let upperBound = Int((Double(maxBPM) + padding).rounded())
        
        return lowerBound...upperBound
    }
    
    private func dataPointAtTime(_ time: TimeInterval, in dataPoints: [TimerViewModel.ChartDataPoint]) -> TimerViewModel.ChartDataPoint? {
        // Find the closest data point to the selected time
        return dataPoints.min(by: { abs($0.time - time) < abs($1.time - time) })
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // Get set boundaries for vertical lines (at start and end of each segment)
    private func setBoundaries() -> [SetBoundary] {
        var boundaryTimes: Set<TimeInterval> = [0] // Always include start
        
        // Add boundaries at start and end of each segment
        for segment in segments {
            boundaryTimes.insert(segment.startTime)
            boundaryTimes.insert(segment.endTime)
        }
        
        // Sort and convert to SetBoundary array
        return boundaryTimes.sorted().map { SetBoundary(time: $0) }
    }
    
    private struct SetBoundary: Identifiable {
        let id = UUID()
        let time: TimeInterval
    }
}

