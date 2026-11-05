import JavaScriptCore
import XCTest
@testable import Plume

final class NewMessageTests: XCTestCase {

    private var ctx: JSContext!

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.evaluateScript(InjectedScript.newMessageMatchJS)
    }

    private func call(_ fn: String, _ arg: String) -> Bool {
        let json = InjectedScript.stringLiteral(arg)!
        return ctx.evaluateScript("__plumeNewMessage.\(fn)(\(json))")?.toBool() ?? false
    }

    func testComposePathsOnBothSites() {
        for path in ["/new", "/new/", "/messages/new", "/messages/new/"] {
            XCTAssertTrue(call("isComposePath", path), path)
        }
        for path in ["/", "/t/123/", "/messages/t/123/", "/news", "/messages/new/x", "/newsfeed", ""] {
            XCTAssertFalse(call("isComposePath", path), path)
        }
    }

    // Exact, accent-folded: "Tin nhắn mới" in either spelling, never a label
    // that merely contains the words.
    func testComposeLabelsAreExact() {
        for label in ["New message", "new  message", "Tin nhắn mới", "Tin nhan moi"] {
            XCTAssertTrue(call("isComposeLabel", label), label)
        }
        for label in ["New messages", "Jump to new message", "Xem tin nhắn mới", "Message", ""] {
            XCTAssertFalse(call("isComposeLabel", label), label)
        }
    }

    func testFallbackURLStaysOnTheSessionsSite() {
        XCTAssertEqual(ThreadURL.newMessageURL(from: URL(string: "https://www.messenger.com/t/1/")),
                       URL(string: "https://www.messenger.com/new/"))
        XCTAssertEqual(ThreadURL.newMessageURL(from: URL(string: "https://www.facebook.com/messages/t/1/")),
                       URL(string: "https://www.facebook.com/messages/new/"))
        XCTAssertEqual(ThreadURL.newMessageURL(from: URL(string: "https://facebook.com/some.profile")),
                       URL(string: "https://www.facebook.com/messages/new/"))
        XCTAssertEqual(ThreadURL.newMessageURL(from: URL(string: "https://web.facebook.com/messages/")),
                       URL(string: "https://web.facebook.com/messages/new/"))
        XCTAssertNil(ThreadURL.newMessageURL(from: URL(string: "https://example.com/new/")))
        XCTAssertNil(ThreadURL.newMessageURL(from: nil))
    }
}
