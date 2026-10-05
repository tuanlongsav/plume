import XCTest
@testable import Plume

final class DisplayHopTests: XCTestCase {

    private let half: CGFloat = 29
    private let margin: CGFloat = 6

    /// Laptop (0,0 1728×1117) and portrait left (−1000,−193 1000×1600).
    private let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let leftPortrait = CGRect(x: -1000, y: -193, width: 1000, height: 1600)
    private let rightPortrait = CGRect(x: 1728, y: -244, width: 1000, height: 1600)

    func testLaptopToLeftPortraitLandsOnSharedSeam() {
        // Came from the right → right edge of the left portrait (x≈−35).
        XCTAssertTrue(DisplayHop.preferRightEdge(
            from: laptop, to: leftPortrait, headX: 35, half: half, margin: margin))
        let x = DisplayHop.edgeX(preferRight: true, visible: leftPortrait,
                                 half: half, margin: margin)
        XCTAssertEqual(x, leftPortrait.maxX - half - margin, accuracy: 0.1)
    }

    func testLeftPortraitToLaptopLandsOnSharedSeam() {
        // Came from the left → left edge of the laptop.
        XCTAssertFalse(DisplayHop.preferRightEdge(
            from: leftPortrait, to: laptop, headX: -35, half: half, margin: margin))
        let x = DisplayHop.edgeX(preferRight: false, visible: laptop,
                                 half: half, margin: margin)
        XCTAssertEqual(x, laptop.minX + half + margin, accuracy: 0.1)
    }

    func testLaptopToRightPortraitLandsOnSharedSeam() {
        XCTAssertFalse(DisplayHop.preferRightEdge(
            from: laptop, to: rightPortrait, headX: 1690, half: half, margin: margin))
        let x = DisplayHop.edgeX(preferRight: false, visible: rightPortrait,
                                 half: half, margin: margin)
        XCTAssertEqual(x, rightPortrait.minX + half + margin, accuracy: 0.1)
    }

    func testStackedKeepsCloserSide() {
        let upper = CGRect(x: 0, y: 1200, width: 1728, height: 1117)
        let lower = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // Head near the right of the upper display → stay on the right below.
        XCTAssertTrue(DisplayHop.preferRightEdge(
            from: upper, to: lower, headX: 1690, half: half, margin: margin))
        XCTAssertFalse(DisplayHop.preferRightEdge(
            from: upper, to: lower, headX: 40, half: half, margin: margin))
    }
}
