//
//  HeartRateChartView.swift
//  BPM
//
//  Created for heart rate chart feature
//

import SwiftUI
import Charts

struct HeartRateChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let bpm: Int
}

struct HeartRateChartSegment: Identifiable, Equatable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let type: SegmentType

    enum SegmentType: Equatable {
        case work
        case rest
        case cooldown
    }
}

extension HeartRateChartDataPoint {
    init(_ point: TimerViewModel.ChartDataPoint) {
        self.init(time: point.time, bpm: point.bpm)
    }
}

extension HeartRateChartSegment {
    init(_ segment: TimerViewModel.ChartSegment) {
        self.init(
            startTime: segment.startTime,
            endTime: segment.endTime,
            type: SegmentType(segment.type)
        )
    }
}

extension HeartRateChartSegment.SegmentType {
    init(_ type: TimerViewModel.ChartSegment.SegmentType) {
        switch type {
        case .work:
            self = .work
        case .rest:
            self = .rest
        case .cooldown:
            self = .cooldown
        }
    }
}

extension WorkoutRecord {
    var chartDataPoints: [HeartRateChartDataPoint] {
        hrSamples.compactMap { sample in
            let time = sample.workoutTime ?? sample.timestamp.timeIntervalSince(startAt)
            guard time >= 0 else { return nil }
            return HeartRateChartDataPoint(time: time, bpm: sample.bpm)
        }
        .sorted { $0.time < $1.time }
    }

    var chartSegments: [HeartRateChartSegment] {
        sets.compactMap { set in
            let startTime = max(0, set.totalTime - set.setTime)
            let endTime = max(startTime, set.totalTime)
            guard endTime >= startTime else { return nil }
            return HeartRateChartSegment(
                startTime: startTime,
                endTime: endTime,
                type: chartSegmentType(for: set)
            )
        }
    }

    var chartMaxTime: TimeInterval {
        max(
            durationSeconds,
            chartDataPoints.map(\.time).max() ?? 0,
            chartSegments.map(\.endTime).max() ?? 0
        )
    }

    private func chartSegmentType(for set: WorkoutSetSummary) -> HeartRateChartSegment.SegmentType {
        if set.isCooldownSet {
            return .cooldown
        }
        if set.isRestSet {
            return .rest
        }
        return .work
    }
}

struct HeartRateChartView: View {
    @ObservedObject var timerViewModel: TimerViewModel
    var isLandscape: Bool = false
    @State private var selectedTime: TimeInterval?
    @State private var isDragging = false

    var body: some View {
        HeartRateTimelineChart(
            dataPoints: timerViewModel.chartDataPoints().map(HeartRateChartDataPoint.init),
            segments: timerViewModel.chartSegments().map(HeartRateChartSegment.init),
            maxTime: timerViewModel.chartMaxTime(),
            selectedTime: $selectedTime,
            isDragging: $isDragging
        )
    }
}

struct WorkoutRecordHeartRateChartView: View {
    let record: WorkoutRecord

    @State private var selectedTime: TimeInterval?
    @State private var isDragging = false

    var body: some View {
        HeartRateTimelineChart(
            dataPoints: record.chartDataPoints,
            segments: record.chartSegments,
            maxTime: record.chartMaxTime,
            selectedTime: $selectedTime,
            isDragging: $isDragging
        )
    }
}

private struct HeartRateTimelineChart: View {
    let dataPoints: [HeartRateChartDataPoint]
    let segments: [HeartRateChartSegment]
    let maxTime: TimeInterval
    @Binding var selectedTime: TimeInterval?
    @Binding var isDragging: Bool

    init(
        dataPoints: [HeartRateChartDataPoint],
        segments: [HeartRateChartSegment],
        maxTime: TimeInterval,
        selectedTime: Binding<TimeInterval?> = .constant(nil),
        isDragging: Binding<Bool> = .constant(false)
    ) {
        self.dataPoints = dataPoints
        self.segments = segments
        self.maxTime = max(maxTime, 1.0)
        self._selectedTime = selectedTime
        self._isDragging = isDragging
    }

    private var yDomain: ClosedRange<Int> {
        yAxisDomain(for: dataPoints)
    }

    var body: some View {
        if dataPoints.isEmpty {
            Chart {}
                .chartXScale(domain: 0...60)
                .chartYScale(domain: 60...180)
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .automatic) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel {
                            if let time = $0.as(Double.self) {
                                Text(formatXAxisMinutes(time))
                            }
                        }
                            .foregroundStyle(.gray)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                Chart {
                    ForEach(segments.filter { $0.type != .work }) { segment in
                        RectangleMark(
                            xStart: .value("Start", segment.startTime),
                            xEnd: .value("End", segment.endTime),
                            yStart: .value("Min", yDomain.lowerBound),
                            yEnd: .value("Max", yDomain.upperBound)
                        )
                        .foregroundStyle(segmentColor(for: segment.type).opacity(0.2))
                    }

                    ForEach(setBoundaries()) { boundary in
                        RuleMark(x: .value("Time", boundary.time))
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }

                    ForEach(dataPoints) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("BPM", point.bpm)
                        )
                        .foregroundStyle(.white)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }

                    if let selectedTime,
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
                    AxisMarks(position: .bottom, values: .automatic) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel {
                            if let time = $0.as(Double.self) {
                                Text(formatXAxisMinutes(time))
                            }
                        }
                            .foregroundStyle(.gray)
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .frame(minWidth: 0)
                }
                .padding(.leading, 8)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .chartBackground { chartProxy in
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
                                            let relativeX = value.location.x - plotFrame.minX
                                            let normalizedX = relativeX / plotFrame.width
                                            let timeValue = normalizedX * maxTime

                                            selectedTime = max(0, min(timeValue, maxTime))
                                        }
                                        .onEnded { _ in
                                            isDragging = false
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selectedTime,
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

    private func segmentColor(for type: HeartRateChartSegment.SegmentType) -> Color {
        switch type {
        case .work:
            return .clear
        case .rest:
            return .green
        case .cooldown:
            return .blue
        }
    }

    private func yAxisDomain(for dataPoints: [HeartRateChartDataPoint]) -> ClosedRange<Int> {
        guard !dataPoints.isEmpty else {
            return 0...200
        }

        let minBPM = dataPoints.map { $0.bpm }.min() ?? 0
        let maxBPM = dataPoints.map { $0.bpm }.max() ?? 200

        let range = Double(maxBPM - minBPM)
        let padding = max(range * 0.1, 10.0)

        let lowerBound = max(0, Int((Double(minBPM) - padding).rounded()))
        let upperBound = Int((Double(maxBPM) + padding).rounded())

        return lowerBound...upperBound
    }

    private func dataPointAtTime(_ time: TimeInterval, in dataPoints: [HeartRateChartDataPoint]) -> HeartRateChartDataPoint? {
        return dataPoints.min(by: { abs($0.time - time) < abs($1.time - time) })
    }

    private func formatXAxisMinutes(_ time: TimeInterval) -> String {
        let minutes = Int((time / 60).rounded())
        return "\(minutes)m"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func setBoundaries() -> [SetBoundary] {
        var boundaryTimes: Set<TimeInterval> = [0]

        for segment in segments {
            boundaryTimes.insert(segment.startTime)
            boundaryTimes.insert(segment.endTime)
        }

        return boundaryTimes.sorted().map { SetBoundary(time: $0) }
    }

    private struct SetBoundary: Identifiable {
        let id = UUID()
        let time: TimeInterval
    }
}
