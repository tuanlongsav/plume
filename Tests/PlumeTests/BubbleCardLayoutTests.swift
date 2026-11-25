import XCTest
@testable import PlumeBubble

final class BubbleCardLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let minSize = CGSize(width: 380, height: 420)
    private let peak: CGFloat = 92

    func testClampedOriginReservesDockedRowLaneAndSnapsToPoints() {
        let size = CGSize(width: 920, height: 700)
        let origin = BubbleCardLayout.clampedOrigin(
            CGPoint(x: -50.4, y: 900.7), cardSize: size, visible: visible, peakDiameter: peak)
        XCTAssertEqual(origin.x, 8)
        XCTAssertEqual(origin.y, visible.maxY - size.height - (peak + 8))
    }

    func testCardOriginAlignsRightOnRightHalfAndLeftOnLeftHalf() {
        let size = CGSize(width: 920, height: 600)
        let leftHead = CGPoint(x: 100, y: 800)
        let leftOrigin = BubbleCardLayout.cardOrigin(
            under: leftHead, cardSize: size, visible: visible, canvas: peak, peakDiameter: peak)
        XCTAssertEqual(leftOrigin.x, (leftHead.x - peak / 2).rounded())

        let rightHead = CGPoint(x: 1650, y: 800)
        let rightOrigin = BubbleCardLayout.cardOrigin(
            under: rightHead, cardSize: size, visible: visible, canvas: peak, peakDiameter: peak)
        XCTAssertEqual(rightOrigin.x, (rightHead.x + peak / 2 - size.width).rounded())
    }

    func testThreadContentSizeEnforcesMessengerFloor() {
        let size = BubbleCardLayout.threadContentSize(
            saved: CGSize(width: 500, height: 640),
            minSize: minSize, visible: visible, peakDiameter: peak)
        XCTAssertEqual(size.width, BubbleCardLayout.messengerFloor)
        XCTAssertEqual(size.height, 640)
    }

    func testThreadContentSizeCapsToSmallDisplay() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = BubbleCardLayout.threadContentSize(
            saved: CGSize(width: 1200, height: 900),
            minSize: minSize, visible: small, peakDiameter: peak)
        XCTAssertEqual(size.width, 800 - 16)
        XCTAssertEqual(size.height, 600 - (peak + 10))
    }

    func testPickerContentSizeUsesPickerMetrics() {
        let size = BubbleCardLayout.pickerContentSize(visible: visible, canvas: peak)
        XCTAssertEqual(size, BubbleCardLayout.pickerSize)
    }

    func testTheaterFrameFillsDisplayBelowDockedLane() {
        let content = BubbleCardLayout.theaterContentSize(
            minSize: minSize, visible: visible, peakDiameter: peak)
        XCTAssertEqual(content.width, visible.width - 20)
        XCTAssertEqual(content.height, visible.height - (peak + 12) - 10)

        let origin = BubbleCardLayout.theaterOrigin(
            frameSize: content, visible: visible, peakDiameter: peak)
        XCTAssertEqual(origin.x, 10)
        XCTAssertEqual(origin.y, 10)
    }

    func testRestoredTheaterSizeClampsSavedDimensions() {
        let restored = BubbleCardLayout.restoredTheaterSize(
            saved: CGSize(width: 100, height: 2000),
            minSize: minSize, visible: visible, peakDiameter: peak)
        XCTAssertEqual(restored.width, minSize.width)
        XCTAssertEqual(restored.height, visible.height - (peak + 10))
    }
}
