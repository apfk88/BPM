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

    @Test func xAxisFitsPhoneWidthForNineteenMinuteWorkout() {
        #expect(HeartRateChartXAxis.tickValues(through: 1152, plotWidth: 320) == [0, 300, 600, 900])
        #expect(HeartRateChartXAxis.tickValues(through: 1152, plotWidth: 160) == [0, 600])
        #expect(HeartRateChartXAxis.tickValues(through: 1152, plotWidth: 768).count > 4)
    }

    @Test func xAxisKeepsShortWorkoutsAndZoomedWindowsReadable() {
        #expect(HeartRateChartXAxis.tickValues(through: 20, plotWidth: 320) == [0, 5, 10, 15, 20])
        #expect(HeartRateChartXAxis.tickValues(through: 175, plotWidth: 320) == [0, 60, 120])
        #expect(HeartRateChartXAxis.tickValues(
            through: 3600, plotWidth: 320, visibleDuration: 60, scrollPosition: 123
        ) == [135, 150, 165, 180])
        #expect(HeartRateChartXAxis.tickValues(
            through: 3600, plotWidth: 320, visibleDuration: 60, scrollPosition: 4000
        ) == [3540, 3555, 3570, 3585, 3600])
    }

    @Test func xAxisScalesForLargerTextAndHandlesInvalidGeometry() {
        #expect(HeartRateChartXAxis.tickValues(
            through: 1152, plotWidth: 320, minimumLabelSpacing: 128
        ) == [0, 600])
        #expect(HeartRateChartXAxis.tickValues(through: 1152, plotWidth: 0) == [0])
        #expect(HeartRateChartXAxis.tickValues(through: .infinity, plotWidth: 320) == [0])
        #expect(HeartRateChartXAxis.tickValues(through: 0, plotWidth: 320) == [0])
    }

    @Test func xAxisUsesCompactElapsedTimeLabels() {
        #expect(HeartRateChartXAxis.label(for: 0) == "0:00")
        #expect(HeartRateChartXAxis.label(for: 30) == "0:30")
        #expect(HeartRateChartXAxis.label(for: 90) == "1:30")
        #expect(HeartRateChartXAxis.label(for: 900) == "15:00")
        #expect(HeartRateChartXAxis.label(for: 3660) == "1:01:00")
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
