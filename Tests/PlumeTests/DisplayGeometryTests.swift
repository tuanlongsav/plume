import XCTest
@testable import PlumeBubble

final class DisplayGeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let leftPortrait = CGRect(x: -1000, y: -193, width: 1000, height: 1600)
    private let rightMonitor = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

    func testNearestFramePicksLargestIntersectionAndHandlesDeadZones() {
        let frames = [laptop, leftPortrait]
        XCTAssertEqual(DisplayHop.nearestFrameIndex(to: CGPoint(x: 500, y: 500), canvas: 92, in: frames), 0)
        XCTAssertEqual(DisplayHop.nearestFrameIndex(to: CGPoint(x: -200, y: 400), canvas: 92, in: frames), 1)
        // Dead zone below laptop (y = -150, x = 200): closer to laptop midpoint than leftPortrait? Wait, check distance:
        // laptop mid=(864, 558.5), leftPortrait mid=(-500, 607): point (100, -150) has dist to laptop ~1041, to left ~965.
        // Dead zone far right above laptop (1700, 1400): strictly nearest to laptop (0).
        XCTAssertEqual(DisplayHop.nearestFrameIndex(to: CGPoint(x: 1700, y: 1400), canvas: 92, in: frames), 0)
        XCTAssertNil(DisplayHop.nearestFrameIndex(to: .zero, canvas: 92, in: []))
    }

    func testFrameBeyondDetectsNeighbourInFlickDirection() {
        let frames = [laptop, leftPortrait, rightMonitor]
        XCTAssertEqual(DisplayHop.frameIndexBeyond(currentIndex: 0, velocity: CGPoint(x: -500, y: 0), in: frames), 1)
        XCTAssertEqual(DisplayHop.frameIndexBeyond(currentIndex: 0, velocity: CGPoint(x: 500, y: 0), in: frames), 2)
        // Below speed floor: no hop.
        XCTAssertNil(DisplayHop.frameIndexBeyond(currentIndex: 0, velocity: CGPoint(x: -50, y: 0), in: frames))
        // No screen above laptop.
        XCTAssertNil(DisplayHop.frameIndexBeyond(currentIndex: 0, velocity: CGPoint(x: 0, y: 500), in: frames))
    }

    func testFrameAcrossSeamDetectsNeighbourNearSharedEdge() {
        let frames = [laptop, leftPortrait]
        // Released near laptop's left edge facing leftPortrait.
        XCTAssertEqual(
            DisplayHop.frameIndexAcrossSeam(
                currentIndex: 0,
                head: CGPoint(x: 112, y: 500),
                cursor: CGPoint(x: 80, y: 500),
                in: frames
            ),
            1
        )
        // Well away from seam: no hop.
        XCTAssertNil(
            DisplayHop.frameIndexAcrossSeam(
                currentIndex: 0,
                head: CGPoint(x: 800, y: 500),
                cursor: CGPoint(x: 800, y: 500),
                in: frames
            )
        )
    }

    func testHopLandingMapsSeamAndPreservesVerticalFraction() {
        let landing = DisplayHop.hopLanding(
            from: laptop, fromVisible: laptop,
            to: leftPortrait, toVisible: leftPortrait,
            head: CGPoint(x: 60, y: laptop.midY),
            half: 46, margin: 6
        )
        XCTAssertTrue(landing.preferRight)
        XCTAssertEqual(landing.point.x, leftPortrait.maxX - 46 - 6, accuracy: 0.1)
        XCTAssertEqual(landing.point.y, leftPortrait.midY, accuracy: 0.1)
    }

    func testInteriorExcludesSharedEdgeStrip() {
        XCTAssertFalse(DisplayHop.isInsideInterior(
            frame: laptop, visibleFrame: laptop, point: CGPoint(x: 20, y: 500), inset: 72))
        XCTAssertTrue(DisplayHop.isInsideInterior(
            frame: laptop, visibleFrame: laptop, point: CGPoint(x: 200, y: 500), inset: 72))
    }
}
