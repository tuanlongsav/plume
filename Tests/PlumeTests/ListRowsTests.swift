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

    // Unread has three tells, and a Vietnamese UI shows only the last two.
    func testRowUnreadSignals() {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        var STYLE = {};   // node id -> computed style
        var window = { getComputedStyle: function (n) { return STYLE[n.id] || {}; } };
        var document = { querySelectorAll: function () { return []; } };
        function node(id, text, kids) { return { id: id, textContent: text, childElementCount: kids || 0 }; }
        function row(o) {
            return {
                innerText: o.text || "",
                querySelector: function (sel) { return o.labelled && sel.indexOf("unread") >= 0 ? {} : null; },
                querySelectorAll: function (sel) {
                    return sel.indexOf("html-span") >= 0 ? (o.notes || []) : (o.spans || []);
                }
            };
        }
        """)
        ctx.evaluateScript(InjectedScript.listRowsJS)
        func unread(_ js: String) -> Bool { ctx.evaluateScript(js)!.toBool() }

        XCTAssertTrue(unread("plumeRowUnread(row({ labelled: true }))"))
        XCTAssertTrue(unread("""
            STYLE.p = { fontWeight: "700" };
            plumeRowUnread(row({ text: "An\\nHẹn mai nhé", spans: [node("p", "Hẹn mai nhé")] }))
            """))
        XCTAssertFalse(unread("""
            STYLE.q = { fontWeight: "400" };
            plumeRowUnread(row({ text: "An\\nHẹn mai nhé", spans: [node("q", "Hẹn mai nhé")] }))
            """))
        XCTAssertTrue(unread("""
            STYLE.h = { position: "absolute", width: "1px", height: "1px", overflow: "hidden" };
            plumeRowUnread(row({ text: "An\\nOk", notes: [node("h", "Tin nhắn chưa đọc")] }))
            """))
        // A hidden note that has children of its own is a container, not the note.
        XCTAssertFalse(unread("""
            STYLE.c = { position: "absolute", width: "1px" };
            plumeRowUnread(row({ text: "An\\nOk", notes: [node("c", "x", 2)] }))
            """))
    }
}
