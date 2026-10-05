import XCTest
@testable import Plume

final class DockedRowTests: XCTestCase {

    private let pad: CGFloat = 8
    private let card = CGRect(x: 200, y: 80, width: 920, height: 640)
    private let visible = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testEmpty() {
        XCTAssertEqual(Chain.dockedRowXs(diameters: [], card: card, visible: visible), [])
    }

    func testSingleHeadCentresOnCard() {
        let d: CGFloat = 48
        let xs = Chain.dockedRowXs(diameters: [d], card: card, visible: visible)
        XCTAssertEqual(xs.count, 1)
        XCTAssertEqual(xs[0], card.midX, accuracy: 0.1)
    }

    func testPackedRowCentresAsAGroup() {
        let d = Chain.base
        let xs = Chain.dockedRowXs(diameters: [d, d, d], card: card, visible: visible)
        XCTAssertEqual(xs.count, 3)
        let last = xs[2]
        let left = xs[0] - d / 2
        let right = last + d / 2
        XCTAssertEqual((left + right) / 2, card.midX, accuracy: 0.1)
        XCTAssertGreaterThan(xs[0], card.minX + pad)
        XCTAssertLessThan(last, card.maxX - pad)
    }

    func testWideRowPinsToCardRightInset() {
        let d = Chain.base
        // Far more heads than a 200pt-wide card can hold. Visible extends
        // well past the card so the screen clamp does not undo the pin.
        let narrow = CGRect(x: 400, y: 0, width: 200, height: 400)
        let wideVisible = CGRect(x: -2000, y: 0, width: 5000, height: 1200)
        let diameters = Array(repeating: d, count: 12)
        let xs = Chain.dockedRowXs(diameters: diameters, card: narrow, visible: wideVisible)
        let last = xs.count - 1
        XCTAssertEqual(xs[last] + d / 2 + pad, narrow.maxX, accuracy: 0.1)
    }
}
