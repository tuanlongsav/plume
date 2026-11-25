import XCTest
@testable import PlumeBubble

final class HoverMagnificationTests: XCTestCase {

    func testUndockedHoverScalesFocusAndImmediateNeighbours() {
        let targets = Chain.hoverTargets(count: 5, focus: 2, docked: false, openIndex: 0)
        let span = Chain.peak - Chain.base
        XCTAssertEqual(targets[0], Chain.base + span * Chain.magNextNeighbour, accuracy: 0.01)
        XCTAssertEqual(targets[1], Chain.base + span * Chain.magNeighbour, accuracy: 0.01)
        XCTAssertEqual(targets[2], Chain.peak, accuracy: 0.01)
        XCTAssertEqual(targets[3], Chain.base + span * Chain.magNeighbour, accuracy: 0.01)
        XCTAssertEqual(targets[4], Chain.base + span * Chain.magNextNeighbour, accuracy: 0.01)
    }

    func testDockedHoverBoostsOpenHeadEvenWithoutPointerFocus() {
        let targets = Chain.hoverTargets(count: 4, focus: nil, docked: true, openIndex: 2)
        let span = Chain.peak - Chain.base
        XCTAssertEqual(targets[0], Chain.base, accuracy: 0.01)
        XCTAssertEqual(targets[1], Chain.base, accuracy: 0.01)
        XCTAssertEqual(targets[2], Chain.base + span * Chain.openBoost, accuracy: 0.01)
        XCTAssertEqual(targets[3], Chain.base, accuracy: 0.01)
    }

    func testDraggingClearsAllMagnification() {
        let targets = Chain.hoverTargets(count: 4, focus: 1, docked: true, openIndex: 2, dragging: true)
        XCTAssertEqual(targets, Array(repeating: Chain.base, count: 4))
    }

    func testPickHoverFocusUsesHysteresisToPreventJitter() {
        let probes = [
            CGPoint(x: 100, y: 500),
            CGPoint(x: 100, y: 500 - Chain.step),
            CGPoint(x: 100, y: 500 - Chain.step * 2),
        ]
        // Pointer directly on probe 0 picks 0.
        let initial = Chain.pickHoverFocus(point: probes[0], probes: probes, currentFocus: nil)
        XCTAssertEqual(initial, 0)

        // Slightly closer to probe 1, but within hysteresis margin: stays on 0.
        let midSlightlyLower = CGPoint(x: 100, y: 500 - Chain.step * 0.55)
        XCTAssertEqual(Chain.pickHoverFocus(point: midSlightlyLower, probes: probes, currentFocus: 0), 0)

        // Clearly past probe 1 switches focus to 1.
        XCTAssertEqual(Chain.pickHoverFocus(point: probes[1], probes: probes, currentFocus: 0), 1)

        // Far outside the field drops focus.
        XCTAssertNil(Chain.pickHoverFocus(point: CGPoint(x: 600, y: 500), probes: probes, currentFocus: 1))
    }

    func testClampedAnchorKeepsWholeColumnOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let clamped = Chain.clampedAnchor(CGPoint(x: 2000, y: 0), visible: visible, count: 4, anchorIndex: 0)
        let half = Chain.canvas / 2
        XCTAssertEqual(clamped.x, visible.maxX - half - Chain.margin, accuracy: 0.01)
        XCTAssertEqual(clamped.y, visible.minY + half + Chain.margin + 3 * Chain.step, accuracy: 0.01)
    }
}
