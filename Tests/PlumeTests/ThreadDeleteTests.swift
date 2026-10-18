import JavaScriptCore
import XCTest
@testable import Plume

final class ThreadDeleteTests: XCTestCase {

    private var ctx: JSContext!

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.evaluateScript(InjectedScript.deleteMatchJS)
    }

    private func match(_ fn: String, _ label: String) -> Bool {
        let json = InjectedScript.stringLiteral(label)!
        return ctx.evaluateScript("__plumeDeleteMatch.\(fn)(\(json))")?.toBool() ?? false
    }

    func testDeleteItemMatchesBothLocalesAndSpellings() {
        XCTAssertTrue(match("isDeleteItem", "Delete chat"))
        XCTAssertTrue(match("isDeleteItem", "Xóa đoạn chat"))
        XCTAssertTrue(match("isDeleteItem", "Xoá đoạn chat"))
        XCTAssertTrue(match("isDeleteItem", "  Delete  Chat "))
    }

    // The same menu holds these. Clicking any of them instead would be a
    // different, equally irreversible action.
    func testDeleteItemRejectsNeighbouringMenuItems() {
        for other in ["Archive chat", "Lưu trữ đoạn chat", "Leave group", "Rời nhóm",
                      "Block", "Chặn", "Mute notifications", "Report", "Delete", "Xóa", ""] {
            XCTAssertFalse(match("isDeleteItem", other), other)
        }
    }

    func testConfirmAcceptsBareDeleteButNotCancel() {
        XCTAssertTrue(match("isConfirm", "Delete chat"))
        XCTAssertTrue(match("isConfirm", "Delete"))
        XCTAssertTrue(match("isConfirm", "Xóa"))
        XCTAssertFalse(match("isConfirm", "Cancel"))
        XCTAssertFalse(match("isConfirm", "Hủy"))
        XCTAssertFalse(match("isConfirm", "Delete for everyone"))
    }

    func testMenuButtonLabels() {
        XCTAssertTrue(match("isMenuButton", "Menu"))
        XCTAssertTrue(match("isMenuButton", "More options for An"))
        XCTAssertTrue(match("isMenuButton", "Tùy chọn khác cho An"))
        XCTAssertFalse(match("isMenuButton", "Mark as read"))
    }

    func testThreadIdIgnoresNamespaceAndQuery() {
        func id(_ href: String) -> String {
            ctx.evaluateScript("__plumeDeleteMatch.threadId('\(href)')")!.toString()
        }
        XCTAssertEqual(id("https://www.messenger.com/t/123/"), "123")
        XCTAssertEqual(id("https://www.messenger.com/e2ee/t/123/?x=1"), "123")
        XCTAssertEqual(id("https://www.messenger.com/"), "")
    }

    func testSwiftThreadIdMatchesAcrossNamespaces() {
        XCTAssertEqual(ThreadURL.id(from: URL(string: "https://www.messenger.com/t/42/?a=b")), "42")
        XCTAssertEqual(ThreadURL.id(from: URL(string: "https://www.messenger.com/e2ee/t/42")), "42")
        XCTAssertNil(ThreadURL.id(from: URL(string: "https://www.messenger.com/")))
    }

    func testOutcomeParsing() {
        XCTAssertEqual(ThreadDeleteOutcome(result: "ok"), .ok)
        XCTAssertNil(ThreadDeleteOutcome(result: "ok").failureMessage)
        XCTAssertEqual(ThreadDeleteOutcome(result: "no-item"), .noItem)
        // Anything unrecognised is a failure, never a success.
        XCTAssertEqual(ThreadDeleteOutcome(result: nil), .failed)
        XCTAssertEqual(ThreadDeleteOutcome(result: "deleted"), .failed)
        XCTAssertNotNil(ThreadDeleteOutcome(result: 1).failureMessage)
    }

    /// `callAsyncJavaScript` wraps this as an async function body; a syntax
    /// error would only surface at the moment the user confirms a delete.
    func testDeleteScriptParses() {
        ctx.evaluateScript("var f = async function (href) {\n\(InjectedScript.deleteThreadJS)\n};")
        XCTAssertNil(ctx.exception, ctx.exception?.toString() ?? "")
    }

    // The thread helpers are spliced into the document-start script and also
    // evaluated on their own; a syntax slip in either breaks every card open.
    func testInjectedScriptsParse() {
        for js in [InjectedScript.source, InjectedScript.threadHelpersJS] {
            ctx.evaluateScript("new Function(\(InjectedScript.stringLiteral(js)!));")
            XCTAssertNil(ctx.exception, ctx.exception?.toString() ?? "")
        }
        XCTAssertTrue(InjectedScript.source.contains(InjectedScript.threadHelpersJS))
    }
}
