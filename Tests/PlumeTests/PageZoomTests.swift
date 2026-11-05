import XCTest
@testable import Plume

final class PageZoomTests: XCTestCase {

    func testStepsAreInverse() {
        var z = PageZoom.actual
        for _ in 0..<3 { z = PageZoom.zoomedIn(from: z) }
        for _ in 0..<3 { z = PageZoom.zoomedOut(from: z) }
        XCTAssertEqual(z, PageZoom.actual)
    }

    func testStepsFollowTheLadder() {
        XCTAssertEqual(PageZoom.zoomedIn(from: 1.0), 1.1)
        XCTAssertEqual(PageZoom.zoomedOut(from: 1.0), 0.9)
        // An off-ladder value moves to the next level in that direction.
        XCTAssertEqual(PageZoom.zoomedIn(from: 1.2), 1.25)
        XCTAssertEqual(PageZoom.zoomedOut(from: 1.2), 1.1)
    }

    func testEndsHold() {
        XCTAssertEqual(PageZoom.zoomedIn(from: 3.0), 3.0)
        XCTAssertEqual(PageZoom.zoomedOut(from: 0.5), 0.5)
        XCTAssertFalse(PageZoom.canZoomIn(3.0))
        XCTAssertFalse(PageZoom.canZoomOut(0.5))
        XCTAssertTrue(PageZoom.canZoomIn(1.0))
        XCTAssertTrue(PageZoom.canZoomOut(1.0))
    }

    // A stored value from defaults is never trusted as is.
    func testClamping() {
        XCTAssertEqual(PageZoom.clamped(9), 3.0)
        XCTAssertEqual(PageZoom.clamped(0.1), 0.5)
        XCTAssertEqual(PageZoom.clamped(.nan), 1.0)
        XCTAssertEqual(PageZoom.clamped(-2), 1.0)
        XCTAssertEqual(PageZoom.clamped(1.25), 1.25)
    }

    func testActual() {
        XCTAssertTrue(PageZoom.isActual(1.0))
        XCTAssertTrue(PageZoom.isActual(1.0000001))
        XCTAssertFalse(PageZoom.isActual(1.1))
    }
}
