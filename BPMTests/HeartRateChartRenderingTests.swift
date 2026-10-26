import XCTest
import SwiftUI
@testable import BPM

final class HeartRateChartRenderingTests: XCTestCase {
    @MainActor func testChartLayouts() async throws {
        let cases: [(String, CGFloat, Double, Double, Double, DynamicTypeSize)] = [
            ("19m-narrow", 280, 1152, 1152, 0, .large),
            ("19m-phone", 390, 1152, 1152, 0, .large),
            ("19m-accessibility", 320, 1152, 1152, 0, .accessibility3),
            ("3h-tablet", 768, 10800, 10800, 0, .large),
            ("3h-zoom-scroll", 320, 10800, 300, 3600, .large)
        ]
        for (name, width, duration, visible, offset, textSize) in cases {
            let data = stride(from: 0.0, through: duration, by: 5).map {
                HeartRateChartDataPoint(time: $0, bpm: 120 + Int(30 * sin($0 / 35)))
            }
            let chart = HeartRateTimelineChart(dataPoints: data, segments: [], maxTime: duration,
                allowsHorizontalScrolling: offset > 0, showsPeakLabels: false,
                selectedTime: .constant(nil), isDragging: .constant(false),
                visibleDuration: .constant(visible), scrollPosition: .constant(offset))
                .environment(\.dynamicTypeSize, textSize)
                .frame(width: width, height: 280).background(.black)
            let host = UIHostingController(rootView: chart)
            host.safeAreaRegions = []
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 280))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size.width, width)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}
