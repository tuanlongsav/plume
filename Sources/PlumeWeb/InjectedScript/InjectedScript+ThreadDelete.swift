import Foundation

extension InjectedScript {
    /// Label matching for the delete-chat flow. No DOM in here, so the tests
    /// can run it in a bare JSContext. Exact (accent-folded) labels only: a
    /// destructive flow must never click something that merely looks close.
    public static let deleteMatchJS = #"""
    (function (g) {
        \#(InjectedScript.normJS)
        var DELETE = ["delete chat", "xoa doan chat",
                      "delete conversation", "xoa cuoc tro chuyen"];
        g.__plumeDeleteMatch = {
            threadId: function (href) {
                var m = /\/t\/([^\/?#]+)/.exec(String(href || ""));
                return m ? m[1] : "";
            },
            // The row's "⋯" button: "Menu", "More options for An",
            // "Tùy chọn khác cho An".
            isMenuButton: function (label) {
                var n = norm(label);
                return n === "menu" || n.indexOf("more options") === 0
                    || n.indexOf("tuy chon khac") === 0;
            },
            isDeleteItem: function (label) { return DELETE.indexOf(norm(label)) !== -1; },
            // The dialog's button repeats the item, or is a bare "Delete".
            isConfirm: function (label) {
                var n = norm(label);
                return n === "delete" || n === "xoa" || DELETE.indexOf(n) !== -1;
            }
        };
    })(typeof window !== "undefined" ? window : this);
    """#

    /// Body for `callAsyncJavaScript` (argument: `href`). Drives Messenger's
    /// own flow — row "⋯" → "Delete chat" → confirm — and resolves to a
    /// `ThreadDeleteOutcome` raw value. Role/label hooks only. A step that
    /// doesn't find its exact control backs out with Escape and clicks nothing
    /// else.
    public static let deleteThreadJS = deleteMatchJS + listRowsJS + #"""
    var M = window.__plumeDeleteMatch;
    var id = M.threadId(href);
    if (!id) return "no-row";

    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
    async function until(fn, ms) {
        var end = Date.now() + ms;
        for (;;) {
            var v = fn();
            if (v) return v;
            if (Date.now() >= end) return null;
            await sleep(60);
        }
    }
    function label(el) {
        var lines = plumeRowLines(el);
        return lines[0] || el.getAttribute("aria-label") || "";
    }
    function fresh(selector, before) {
        return Array.prototype.filter.call(document.querySelectorAll(selector),
            function (el) { return before.indexOf(el) === -1; });
    }
    function snapshot(selector) {
        return Array.prototype.slice.call(document.querySelectorAll(selector));
    }
    function backOut() {
        try {
            (document.activeElement || document.body).dispatchEvent(new KeyboardEvent(
                "keydown", { key: "Escape", code: "Escape", keyCode: 27, which: 27,
                             bubbles: true, cancelable: true }));
        } catch (e) {}
    }
    function findRow() {
        var rows = plumeListRows();
        for (var i = 0; i < rows.length; i++) {
            var link = rows[i].querySelector('a[role="link"][href]');
            if (link && M.threadId(link.href) === id) return rows[i];
        }
        return null;
    }

    var row = findRow();
    if (!row) return "no-row";
    try { row.scrollIntoView({ block: "nearest" }); } catch (e) {}

    // The "⋯" button is only mounted while the row is hovered.
    var hoverTarget = row.querySelector('a[role="link"]') || row;
    ["pointerover", "pointerenter", "mouseover", "mouseenter", "mousemove"].forEach(function (t) {
        try {
            hoverTarget.dispatchEvent(new MouseEvent(t,
                { bubbles: true, cancelable: true, view: window }));
        } catch (e) {}
    });
    var button = await until(function () {
        var c = row.querySelectorAll('[role="button"][aria-label], [aria-haspopup="menu"]');
        for (var i = 0; i < c.length; i++) {
            if (M.isMenuButton(c[i].getAttribute("aria-label"))) return c[i];
        }
        var pop = row.querySelectorAll('[aria-haspopup="menu"]');
        return pop.length === 1 ? pop[0] : null;
    }, 2000);
    if (!button) return "no-menu";

    var menusBefore = snapshot('[role="menu"]');
    button.click();
    var item = await until(function () {
        var menus = fresh('[role="menu"]', menusBefore);
        for (var m = 0; m < menus.length; m++) {
            var items = menus[m].querySelectorAll('[role="menuitem"]');
            for (var i = 0; i < items.length; i++) {
                if (M.isDeleteItem(label(items[i]))) return items[i];
            }
        }
        return null;
    }, 2500);
    if (!item) { backOut(); return "no-item"; }

    var dialogsBefore = snapshot('[role="dialog"], [role="alertdialog"]');
    item.click();
    var confirm = await until(function () {
        var dialogs = fresh('[role="dialog"], [role="alertdialog"]', dialogsBefore);
        for (var d = 0; d < dialogs.length; d++) {
            var buttons = dialogs[d].querySelectorAll('[role="button"], button');
            for (var i = 0; i < buttons.length; i++) {
                if (buttons[i].getAttribute("aria-disabled") === "true") continue;
                if (M.isConfirm(label(buttons[i]))) return buttons[i];
            }
        }
        return null;
    }, 3000);
    if (!confirm) { backOut(); return "no-confirm"; }

    confirm.click();
    var gone = await until(function () { return !findRow(); }, 6000);
    return gone ? "ok" : "timeout";
    """#
}
