import Foundation

/// JavaScript and minimal CSS injected into the Messenger page.
///
/// Split across domain extensions (`+Notifications`, `+Conversations`,
/// `+ThreadDelete`, `+BubbleCard`, `+Styles`) and assembled here into `source`.
/// Every script must remain compatible with macOS 13.3's WebKit (Safari 16.4),
/// enforced by `WebFloorTests`.
public enum InjectedScript {
    /// Accent-folded, whitespace-collapsed, lower-cased text, so a label
    /// matches whether Messenger renders it in Vietnamese or English. đ/Đ
    /// (U+0111/U+0110) have no canonical decomposition, so NFD leaves them
    /// intact and they are folded by hand. Spliced into each script that
    /// needs it: those run in separate scopes and some are tested standalone.
    public static let normJS = #"""
    function norm(s) {
        s = String(s || "");
        try { s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, ""); } catch (e) {}
        return s.replace(/[\u0111\u0110]/g, "d")
            .replace(/\s+/g, " ").trim().toLowerCase();
    }
    """#

    /// The chat list's rows: `[role=row]`s holding a link to a thread, outside
    /// the open conversation (`[role=main]`) and outside Facebook's top bar
    /// (`[role=banner]`), whose Messenger popover is a list of chats too. Rows
    /// in the navigation's grid come first: that is the list itself on both
    /// messenger.com and facebook.com/messages. Spliced into each script that
    /// needs it, like `normJS`; function declarations, so they are hoisted.
    public static let listRowsJS = #"""
    function plumeRowLines(el) {
        return (el.innerText || el.textContent || "").split("\n")
            .map(function (x) { return x.trim(); }).filter(Boolean);
    }
    function plumeListRows() {
        var all = document.querySelectorAll('[role="row"]');
        var inList = [], other = [];
        for (var i = 0; i < all.length; i++) {
            var r = all[i];
            if (r.closest('[role="main"]') || r.closest('[role="banner"]')) continue;
            var link = r.querySelector('a[role="link"][href]');
            if (!link || link.href.indexOf('/t/') === -1) continue;
            (r.closest('[role="navigation"] [role="grid"]') ? inList : other).push(r);
        }
        return inList.length ? inList : other;
    }
    // Whether a chat-list row is unread. The accessible label says so in some
    // locales only (never on a Vietnamese UI). Messenger also renders an
    // unread row's preview semibold, and facebook.com adds a visually hidden
    // screen-reader note inside an `html-span` (a stable class, not a hashed
    // one) that other hidden notes ("Online now", "Sent") do not sit in.
    function plumeRowUnread(row, preview) {
        if (row.querySelector('[aria-label*="unread" i], [aria-label*="chưa đọc" i]')) return true;
        try {
            if (preview === undefined) {
                var lines = plumeRowLines(row);
                preview = (lines[1] || "").slice(0, 80);
            }
            if (preview) {
                var probe = preview.slice(0, 12);
                var nodes = row.querySelectorAll('[dir="auto"], span');
                for (var q = 0; q < nodes.length; q++) {
                    var txt = (nodes[q].textContent || "").trim();
                    if (!txt || txt.indexOf(probe) !== 0) continue;
                    var fw = parseInt(window.getComputedStyle(nodes[q]).fontWeight, 10) || 400;
                    if (fw >= 600) return true;
                    break;
                }
            }
            var notes = row.querySelectorAll('.html-span > span, .html-span > div');
            for (var h = 0; h < notes.length; h++) {
                var n = notes[h];
                if (n.childElementCount !== 0 || !(n.textContent || "").trim()) continue;
                var cs = window.getComputedStyle(n);
                if (cs.position === "absolute"
                    && (cs.width === "1px" || cs.height === "1px" || cs.overflow === "hidden")) {
                    return true;
                }
            }
        } catch (e) {}
        return false;
    }
    """#

    /// Full document-start user script assembled from all domain modules.
    public static let source = newMessageMatchJS + notifyTagsJS + #"""
    (function () {
        "use strict";
        if (window.__plumeInstalled) return;
        window.__plumeInstalled = true;

        const bridge = window.webkit && window.webkit.messageHandlers;
        function post(channel, payload) {
            try { bridge && bridge[channel] && bridge[channel].postMessage(payload); }
            catch (e) { /* no-op */ }
        }

    """#
        + notificationBridgeJS
        + styleInjectionJS
        + conversationNavJS
        + threadHelpersJS
        + hideSkipLinksJS
        + theaterDetectJS
        + conversationSnapshotJS
        + #"""

        // Note: the unread badge is derived natively by observing WKWebView's
        // `title` (a public, injection-independent signal), so there is no
        // badge bridge here.
    })();
    """#

    /// Escape a Swift string for safe interpolation into evaluated JavaScript.
    public static func stringLiteral(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
