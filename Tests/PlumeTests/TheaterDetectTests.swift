import JavaScriptCore
import XCTest
@testable import Plume

final class TheaterDetectTests: XCTestCase {

    private var ctx: JSContext!

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.evaluateScript(InjectedScript.theaterDetectJS)
    }

    private func isTheater(_ info: [String: Any]) -> Bool {
        let data = try! JSONSerialization.data(withJSONObject: info)
        let json = String(data: data, encoding: .utf8)!
        return ctx.evaluateScript("__plumeIsPhotoTheater(\(json))")?.toBool() ?? false
    }

    /// Composer emoji panel on the 920pt bubble card — used to match the
    /// old "dialog ≥ 32% of the viewport" rule and thrash the window.
    func testEmojiPickerIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 360, "dh": 420,
            "label": "Biểu tượng cảm xúc",
            "largeMedia": 0, "smallImgs": 64
        ]))
    }

    func testEnglishEmojiPickerIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 360, "dh": 420,
            "label": "Choose an emoji",
            "largeMedia": 0, "smallImgs": 48
        ]))
    }

    func testStickerGridIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 380, "dh": 440,
            "label": "Stickers",
            "largeMedia": 0, "smallImgs": 20
        ]))
    }

    func testGifPickerIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 380, "dh": 480,
            "label": "GIF",
            "largeMedia": 0, "smallImgs": 12
        ]))
    }

    func testReactionBarIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 280, "dh": 48,
            "label": "Bày tỏ cảm xúc",
            "largeMedia": 0, "smallImgs": 7
        ]))
    }

    func testForwardSheetWithoutPhotoIsNotTheater() {
        XCTAssertFalse(isTheater([
            "vw": 920, "vh": 700, "dw": 560, "dh": 500,
            "label": "Forward",
            "largeMedia": 0, "smallImgs": 0
        ]))
    }

    func testPhotoLightboxIsTheater() {
        XCTAssertTrue(isTheater([
            "vw": 920, "vh": 700, "dw": 920, "dh": 700,
            "label": "",
            "largeMedia": 1, "smallImgs": 0
        ]))
    }

    func testGiftLabelIsNotConfusedWithGif() {
        // Word-boundary: "gift" must not match the GIF picker key.
        XCTAssertTrue(isTheater([
            "vw": 920, "vh": 700, "dw": 920, "dh": 700,
            "label": "Gift photo",
            "largeMedia": 1, "smallImgs": 0
        ]))
    }
}
