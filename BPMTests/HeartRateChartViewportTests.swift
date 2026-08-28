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
}
