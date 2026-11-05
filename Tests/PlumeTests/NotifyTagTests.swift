import JavaScriptCore
import XCTest
@testable import Plume

/// Native code keys a tagged notification's banner on its tag
/// (`plume-tag-<tag>`), so a newer notification for the same conversation
/// replaces the older banner. The older notification's close() is then a
/// no-op, as in the Notifications spec: it must not take the newer one down.
final class NotifyTagTests: XCTestCase {

    private var ctx: JSContext!

    override func setUp() {
        super.setUp()
        ctx = JSContext()
        ctx.evaluateScript(InjectedScript.notifyTagsJS)
        ctx.evaluateScript("var tags = __plumeNotifyTags();")
    }

    private func shown(_ tag: String, _ id: Int) {
        ctx.evaluateScript("tags.shown(\(InjectedScript.stringLiteral(tag)!), \(id))")
    }

    /// Whether close() of notification `id` may remove the banner.
    private func closes(_ tag: String, _ id: Int) -> Bool {
        ctx.evaluateScript("tags.closes(\(InjectedScript.stringLiteral(tag)!), \(id))")!.toBool()
    }

    func testClosingAReplacedNotificationLeavesTheNewerBanner() {
        shown("thread-1", 1)
        shown("thread-1", 2)
        XCTAssertFalse(closes("thread-1", 1))
        XCTAssertTrue(closes("thread-1", 2))
    }

    func testAClosedNotificationCannotCloseItsSuccessor() {
        shown("thread-1", 1)
        XCTAssertTrue(closes("thread-1", 1))
        shown("thread-1", 2)
        XCTAssertFalse(closes("thread-1", 1))
        XCTAssertTrue(closes("thread-1", 2))
    }

    func testTagsAreIndependent() {
        shown("thread-1", 1)
        shown("thread-2", 2)
        XCTAssertTrue(closes("thread-1", 1))
        XCTAssertTrue(closes("thread-2", 2))
    }

    /// An untagged notification has a banner of its own (`plume-<id>`).
    func testUntaggedNotificationsAlwaysClose() {
        shown("", 1)
        shown("", 2)
        XCTAssertTrue(closes("", 1))
        XCTAssertTrue(closes("", 2))
    }

    /// The page may never call close(), so the table is bounded: it forgets
    /// the tag shown longest ago, whose close() then acts as it used to.
    func testTheTableForgetsTheLeastRecentlyShownTag() {
        shown("old", 1)
        shown("old", 2)
        for i in 3..<503 { shown("t\(i)", i) }
        XCTAssertTrue(closes("old", 1))
    }

    /// A conversation that keeps notifying is never the one forgotten.
    func testShowingATagAgainKeepsIt() {
        shown("busy", 1)
        for i in 2..<400 { shown("t\(i)", i) }
        shown("busy", 400)
        for i in 401..<700 { shown("u\(i)", i) }
        XCTAssertFalse(closes("busy", 1))
    }
}
