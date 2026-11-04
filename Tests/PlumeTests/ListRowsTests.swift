import JavaScriptCore
import XCTest
@testable import Plume

/// `plumeListRows` decides what every chat-list helper clicks, so a row from
/// Facebook's top-bar popover must never count. Run in a bare JSContext with
/// stand-in rows: each knows which ancestor selectors it sits under.
final class ListRowsTests: XCTestCase {
    private func listedIDs(_ rows: String) -> [String] {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        function row(id, href, under) {
            return {
                id: id,
                closest: function (sel) { return under.indexOf(sel) >= 0 ? {} : null; },
                querySelector: function () { return href ? { href: href } : null; }
            };
        }
        var NAV = '[role="navigation"] [role="grid"]';
        var ROWS = \(rows);
        var document = { querySelectorAll: function () { return ROWS; } };
        """)
        ctx.evaluateScript(InjectedScript.listRowsJS)
        let ids = ctx.evaluateScript("plumeListRows().map(function (r) { return r.id; })")
        return ids?.toArray() as? [String] ?? ["<error>"]
    }

    func testKeepsOnlyTheChatListOnFacebook() {
        let ids = listedIDs("""
        [row("popover", "https://www.facebook.com/messages/t/1/", ['[role="banner"]']),
         row("list-a", "https://www.facebook.com/messages/t/2/", [NAV]),
         row("open-thread", "https://www.facebook.com/messages/t/3/", [NAV, '[role="main"]']),
         row("not-a-chat", "https://www.facebook.com/someone", [NAV]),
         row("no-link", "", [NAV]),
         row("stray", "https://www.facebook.com/messages/t/4/", []),
         row("list-b", "https://www.facebook.com/messages/e2ee/t/5/", [NAV])]
        """)
        XCTAssertEqual(ids, ["list-a", "list-b"])
    }

    // Without a navigation grid (an older or changed layout) any thread row
    // outside the open conversation and the top bar still counts.
    func testFallsBackWhenThereIsNoListGrid() {
        let ids = listedIDs("""
        [row("popover", "https://www.facebook.com/messages/t/1/", ['[role="banner"]']),
         row("a", "https://www.messenger.com/t/2/", []),
         row("open-thread", "https://www.messenger.com/t/3/", ['[role="main"]']),
         row("b", "https://www.messenger.com/e2ee/t/4/", [])]
        """)
        XCTAssertEqual(ids, ["a", "b"])
    }
}
