import Testing
@testable import BPM

struct HeartRateChartViewportTests {
    @Test func zoomClampsToFullWorkoutAndMinimumWindow() {
        let viewport = HeartRateChartViewport(totalDuration: 600)

        #expect(viewport.visibleDuration(startingAt: 600, magnification: 2) == 300)
        #expect(viewport.visibleDuration(startingAt: 600, magnification: 100) == 60)
        #expect(viewport.visibleDuration(startingAt: 300, magnification: 0.1) == 600)
    }

    @Test func shortWorkoutCanStillZoomWithoutInvalidDomain() {
        let viewport = HeartRateChartViewport(totalDuration: 30)

        #expect(viewport.minimumVisibleDuration == 10)
        #expect(viewport.visibleDuration(startingAt: 30, magnification: 10) == 10)
    }

    @Test func scrollPositionStaysInsideVisibleTimeline() {
        let viewport = HeartRateChartViewport(totalDuration: 600)

        #expect(viewport.clampedScrollPosition(-20, visibleDuration: 120) == 0)
        #expect(viewport.clampedScrollPosition(240, visibleDuration: 120) == 240)
        #expect(viewport.clampedScrollPosition(590, visibleDuration: 120) == 480)
    }

    @Test func xAxisAlwaysUsesThirtySecondLabels() {
        #expect(HeartRateChartXAxis.tickValues(through: 20) == [0])
        #expect(HeartRateChartXAxis.tickValues(through: 175) == [0, 30, 60, 90, 120, 150])
        #expect(HeartRateChartXAxis.tickValues(through: 180) == [0, 30, 60, 90, 120, 150, 180])
        #expect(HeartRateChartXAxis.label(for: 30) == "30s")
        #expect(HeartRateChartXAxis.label(for: 60) == "1m")
        #expect(HeartRateChartXAxis.label(for: 90) == "1m30s")
        #expect(HeartRateChartXAxis.label(for: 120) == "2m")
    }

    @Test func peakLabelsSelectMajorLocalMaximumPerVisibleBucket() {
        let points = [
            HeartRateChartDataPoint(time: 0, bpm: 100),
            HeartRateChartDataPoint(time: 5, bpm: 120),
            HeartRateChartDataPoint(time: 10, bpm: 100),
            HeartRateChartDataPoint(time: 15, bpm: 110),
            HeartRateChartDataPoint(time: 20, bpm: 130),
            HeartRateChartDataPoint(time: 25, bpm: 105),
            HeartRateChartDataPoint(time: 30, bpm: 100)
        ]

        let zoomedPeaks = HeartRateChartPeaks.majorPeaks(in: points, visibleDuration: 60)
        #expect(zoomedPeaks.map(\.bpm) == [120, 130])

        let zoomedOutPeaks = HeartRateChartPeaks.majorPeaks(in: points, visibleDuration: 120)
        #expect(zoomedOutPeaks.map(\.bpm) == [130])
    }
}
