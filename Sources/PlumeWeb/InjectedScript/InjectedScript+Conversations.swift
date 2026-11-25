import Foundation

extension InjectedScript {
    /// Recognising Messenger's own "New message" control. No DOM in here, so
    /// the tests run it in a bare JSContext. By its link target first (`/new`
    /// on messenger.com, `/messages/new` on facebook.com), then by its exact,
    /// accent-folded label; "Tin nhắn mới" is also the label of the "jump to
    /// new messages" pill, which `newMessage()` excludes by looking only
    /// outside the open conversation.
    public static let newMessageMatchJS = #"""
    (function (g) {
        \#(InjectedScript.normJS)
        var LABELS = ["new message", "tin nhan moi"];
        g.__plumeNewMessage = {
            isComposePath: function (path) {
                var p = String(path || "").replace(/\/+$/, "");
                return p === "/new" || p === "/messages/new";
            },
            isComposeLabel: function (label) { return LABELS.indexOf(norm(label)) !== -1; }
        };
    })(typeof window !== "undefined" ? window : this);
    """#

    /// Conversation keyboard navigation (adapted from Caprine browser.ts,
    /// MIT © Sindre Sorhus). Role-based selectors avoid Meta's hashed class
    /// churn; conversation-list rows live OUTSIDE the open thread ([role=main]).
    static let conversationNavJS = #"""
        // --- Conversation navigation (adapted from Caprine browser.ts,
        //     MIT © Sindre Sorhus). Role-based selectors avoid Meta's hashed
        //     class churn; conversation-list rows live OUTSIDE the open thread
        //     ([role=main]). No-ops harmlessly if the DOM shifts. -------------
        window.__plumeConv = (function () {
            function rows() { return plumeListRows(); }
            function click(row) {
                if (!row) return false;
                var link = row.querySelector('[role="link"]') ||
                           row.querySelector('[role="gridcell"]') || row;
                link.click();
                return true;
            }
            function selectedIndex() {
                var r = rows();
                for (var i = 0; i < r.length; i++) {
                    if (r[i].querySelector('[aria-current="page"]')) return i;
                }
                return -1;
            }
            return {
                jumpTo: function (n) { return click(rows()[n - 1]); },
                next: function () {
                    var r = rows(); if (!r.length) return false;
                    var i = selectedIndex();
                    return click(r[(i + 1 + r.length) % r.length] || r[0]);
                },
                prev: function () {
                    var r = rows(); if (!r.length) return false;
                    var i = selectedIndex();
                    if (i < 0) return click(r[0]);   // mirror next() from no selection
                    return click(r[(i - 1 + r.length) % r.length]);
                },
                nextUnread: function () {
                    var r = rows(); if (!r.length) return false;
                    var start = Math.max(0, selectedIndex());
                    for (var s = 1; s <= r.length; s++) {
                        var idx = (start + s) % r.length;
                        if (plumeRowUnread(r[idx])) return click(r[idx]);
                    }
                    return false;
                },
                // Messenger's own compose control, in the chat list's
                // navigation and never inside the open conversation or the
                // top bar. Clicked, not loaded: a page load would empty the
                // list. False when it is not there; native code decides.
                newMessage: function () {
                    var M = window.__plumeNewMessage;
                    if (!M) return false;
                    var first = rows()[0];
                    var scope = (first && first.closest('[role="navigation"]')) || document;
                    function outside(el) {
                        return !el.closest('[role="main"]') && !el.closest('[role="banner"]');
                    }
                    var links = scope.querySelectorAll('a[href]');
                    for (var i = 0; i < links.length; i++) {
                        var path = "";
                        try { path = new URL(links[i].href, location.href).pathname; } catch (e) { continue; }
                        if (outside(links[i]) && M.isComposePath(path)) { links[i].click(); return true; }
                    }
                    var labelled = scope.querySelectorAll('[role="button"][aria-label], a[aria-label]');
                    for (var j = 0; j < labelled.length; j++) {
                        if (outside(labelled[j]) && M.isComposeLabel(labelled[j].getAttribute("aria-label"))) {
                            labelled[j].click();
                            return true;
                        }
                    }
                    return false;
                },
                // The chat list's own search, not "Search Facebook" in the
                // top bar, which comes first in the document on facebook.com.
                find: function () {
                    var r = rows()[0];
                    var nav = r && r.closest('[role="navigation"]');
                    var el = nav && nav.querySelector('[type="search"]');
                    if (!el) {
                        var all = document.querySelectorAll('[type="search"]');
                        for (var i = 0; i < all.length && !el; i++) {
                            if (!all[i].closest('[role="banner"]')) el = all[i];
                        }
                    }
                    if (el) { el.focus(); return true; }
                    return false;
                }
            };
        })();

    """#

    /// On-demand inbox snapshot, virtualised list expander, facebook.com unread
    /// counter, and sidebar right-click hook.
    static let conversationSnapshotJS = #"""
        // --- Conversation list snapshot (chat bubbles) -----------------
        // Read ON DEMAND only — never an observer — so it costs nothing while
        // idle. Role/attr hooks only, so Meta's hashed class churn cannot break
        // it.
        //
        // NOTE ON WHAT THIS READS: name, avatar, unread flag, the last
        // message's first 80 characters, and the relative timestamp. The
        // preview IS message content: it is shown in the picker and searched
        // there, and it never leaves the machine. Collapsed bubbles still show
        // no message text — that is what the chat heads are for.
        window.__plumeConvList = function (limit) {
            var out = [];
            try {
                var rows = plumeListRows();
                for (var i = 0; i < rows.length && out.length < limit; i++) {
                    var r = rows[i];
                    var link = r.querySelector('a[role="link"][href]');
                    var img = r.querySelector('img');
                    // Read the row's own lines rather than slicing the
                    // aria-label at its first comma: a group thread is named
                    // "An, Bình, Chi", so that split named the bubble "An" and
                    // left the rest of the group's name standing in for the
                    // last message.
                    var label = "", preview = "", time = "";
                    try {
                        var t = plumeRowLines(r);
                        label = t[0] || "";
                        var rest = t.slice(1);
                        preview = (rest[0] || "").slice(0, 80);
                        // The timestamp is the last SHORT line that reads as a
                        // duration or a clock time. Matching on shape, not on
                        // position: some rows end with a suggested reply
                        // ("Trả lời?"), which is not a timestamp.
                        var stampish = /^(\d{1,2}:\d{2}|\d+\s*(phút|giờ|ngày|tuần|năm|thg|m|h|d|w|y))$/i;
                        for (var k = rest.length - 1; k >= 0; k--) {
                            var cand = rest[k];
                            if (cand !== preview && cand.length <= 14 && stampish.test(cand)) {
                                time = cand; break;
                            }
                        }
                    } catch (e) {}
                    if (!label) {
                        // innerText empty (virtualised row): fall back to the
                        // accessible name, which for a 1:1 chat is just a name.
                        label = (link.getAttribute('aria-label') || '').split(',')[0];
                    }
                    label = String(label).trim().slice(0, 60);

                    var unread = plumeRowUnread(r, preview);
                    out.push({
                        href: link.href,
                        name: label,
                        preview: preview,
                        time: time,
                        avatar: img ? img.src : "",
                        unread: unread
                    });
                }
            } catch (e) { /* DOM shifted — return whatever we got */ }
            return JSON.stringify(out);
        };

        // Nudge Messenger's virtualised inbox so older threads enter the DOM
        // before the next `__plumeConvList` snapshot. Returns true when the
        // scroll position actually moved (more history may still be available).
        window.__plumeExpandConvList = function () {
            try {
                var seed = plumeListRows()[0];
                if (!seed) return false;
                var el = seed.parentElement;
                for (var d = 0; d < 14 && el; d++, el = el.parentElement) {
                    if (el.scrollHeight <= el.clientHeight + 40) continue;
                    var before = el.scrollTop;
                    var step = Math.max(el.clientHeight * 0.95, 560);
                    el.scrollTop = Math.min(el.scrollTop + step, el.scrollHeight);
                    return el.scrollTop > before + 1;
                }
            } catch (e) {}
            return false;
        };

        // Unread chats in the list, for the Dock badge on facebook.com, whose
        // title count also takes in notifications Plume cannot clear. -1 when
        // the list cannot be read, so native code keeps the badge it has.
        window.__plumeUnreadCount = function () {
            try {
                var rows = plumeListRows(), n = 0;
                if (!rows.length) {
                    // Empty: either no chats, or the inbox is not in the DOM
                    // (card-thread clip / SPA settle). Only trust zero when the
                    // list grid is still mounted — otherwise a transient miss
                    // blanked the Dock badge on every new message while the
                    // bubble card was open.
                    return document.querySelector('[role="navigation"] [role="grid"]')
                        ? 0 : -1;
                }
                for (var i = 0; i < rows.length; i++) if (plumeRowUnread(rows[i])) n++;
                return n;
            } catch (e) { return -1; }
        };

        // --- Right-click a sidebar row → native menu (delete chat) ------
        // Only rows of the conversation list; a right-click anywhere else
        // keeps WebKit's own menu.
        document.addEventListener("contextmenu", function (e) {
            try {
                var row = e.target && e.target.closest && e.target.closest('[role="row"]');
                if (!row || plumeListRows().indexOf(row) === -1) return;
                var link = row.querySelector('a[role="link"][href]');
                var name = plumeRowLines(row)[0]
                    || (link.getAttribute('aria-label') || '').split(',')[0];
                e.preventDefault();
                e.stopPropagation();
                post("rowMenu", { href: link.href, name: String(name).trim().slice(0, 60) });
            } catch (err) {}
        }, true);
    """#
}
