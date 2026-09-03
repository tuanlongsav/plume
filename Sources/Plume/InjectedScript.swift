import Foundation

/// JavaScript injected at document start into the Messenger page.
///
/// It reroutes the web `Notification` API to native macOS notifications
/// (so they look and behave like a real app, and survive the page being
/// in the background), and lets a native click reopen the right thread.
enum InjectedScript {
    static let source = #"""
    (function () {
        "use strict";
        if (window.__plumeInstalled) return;
        window.__plumeInstalled = true;

        const bridge = window.webkit && window.webkit.messageHandlers;
        function post(channel, payload) {
            try { bridge && bridge[channel] && bridge[channel].postMessage(payload); }
            catch (e) { /* no-op */ }
        }

        // --- Native notification bridge --------------------------------
        const live = new Map();   // id -> Notification instance
        const MAX_LIVE = 500;     // cap so a long session can't grow this forever
        let seq = 0;

        const NativeNotification = function (title, options) {
            options = options || {};
            const id = ++seq;
            this._id = id;
            this.title = title;
            this.body = options.body || "";
            this.icon = options.icon || "";
            this.tag = options.tag || "";
            this.data = options.data;
            this.onclick = null;
            this.onclose = null;
            this.onerror = null;
            this.onshow = null;
            live.set(id, this);
            // Evict the oldest entries if the page never calls close().
            // Map preserves insertion order, so the first key is the oldest.
            while (live.size > MAX_LIVE) {
                const oldest = live.keys().next().value;
                if (oldest === undefined) break;
                live.delete(oldest);
            }
            post("notify", {
                id: id,
                title: String(title || ""),
                body: String(this.body || ""),
                icon: String(this.icon || ""),
                tag: String(this.tag || "")
            });
            // Fire onshow after the caller has had a chance to assign it
            // (the spec delivers it asynchronously, not from the constructor).
            const self = this;
            setTimeout(function () {
                if (typeof self.onshow === "function") {
                    try { self.onshow(); } catch (e) {}
                }
            }, 0);
        };
        NativeNotification.prototype.close = function () {
            live.delete(this._id);
            post("notifyClose", { id: this._id });
        };
        NativeNotification.prototype.addEventListener = function (type, cb) {
            if (type === "click") this.onclick = cb;
            else if (type === "close") this.onclose = cb;
            else if (type === "show") this.onshow = cb;
            else if (type === "error") this.onerror = cb;
        };
        NativeNotification.prototype.removeEventListener = function () {};
        NativeNotification.requestPermission = function (cb) {
            const result = "granted";
            if (typeof cb === "function") cb(result);
            return Promise.resolve(result);
        };
        Object.defineProperty(NativeNotification, "permission", {
            get: function () { return "granted"; }
        });
        Object.defineProperty(NativeNotification, "maxActions", { get: function () { return 0; } });

        try {
            Object.defineProperty(window, "Notification", {
                configurable: true,
                writable: true,
                value: NativeNotification
            });
        } catch (e) {
            window.Notification = NativeNotification;
        }

        // Called by native when the user clicks a delivered notification.
        window.__plumeActivateNotification = function (id) {
            const n = live.get(id);
            if (!n) { return false; }
            const ev = { type: "click", target: n, preventDefault: function () {}, stopPropagation: function () {} };
            try { window.focus(); } catch (e) {}
            if (typeof n.onclick === "function") {
                try { n.onclick(ev); } catch (e) {}
            }
            return true;
        };

        // --- Style injection (tầng B theming) ------------------------
        // Native code toggles Plume's CSS layers by id via these helpers.
        window.__plumeSetStyle = function (id, css) {
            let el = document.getElementById(id);
            if (!el) {
                el = document.createElement("style");
                el.id = id;
                (document.head || document.documentElement).appendChild(el);
            }
            el.textContent = css;
        };
        window.__plumeRemoveStyle = function (id) {
            const el = document.getElementById(id);
            if (el) el.remove();
        };

        // --- Conversation navigation (adapted from Caprine browser.ts,
        //     MIT © Sindre Sorhus). Role-based selectors avoid Meta's hashed
        //     class churn; conversation-list rows live OUTSIDE the open thread
        //     ([role=main]). No-ops harmlessly if the DOM shifts. -------------
        window.__plumeConv = (function () {
            function rows() {
                return Array.prototype.slice
                    .call(document.querySelectorAll('[role="row"]'))
                    .filter(function (r) { return !r.closest('[role="main"]'); });
            }
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
                        if (r[idx].querySelector('[aria-label*="unread" i], [aria-label*="chưa đọc" i]')) {
                            return click(r[idx]);
                        }
                    }
                    return false;
                },
                find: function () {
                    var el = document.querySelector('[type="search"]');
                    if (el) { el.focus(); return true; }
                    return false;
                }
            };
        })();

        // Note: the unread badge is derived natively by observing WKWebView's
        // `title` (a public, injection-independent signal), so there is no
        // badge bridge here.
    })();
    """#

    // MARK: - Tầng B stylesheets

    /// Style ids used by `__plumeSetStyle` / `__plumeRemoveStyle`.
    ///
    /// ⚠️ PERFORMANCE RULE for anything added here: Messenger is a huge
    /// virtualised React app, so every injected selector is re-matched against
    /// each of the thousands of nodes it inserts while paginating. Keep rules
    /// few, narrowly scoped, and never universal. A previous `*::-webkit-
    /// scrollbar` block replaced WebKit's native overlay scrollbars with custom
    /// ones on *every* scrollable element, and a per-bubble box-shadow painted
    /// on every message — together they made loading old messages crawl and
    /// starved new-message updates. Both were removed; don't reintroduce them.
    enum StyleID {
        static let density = "plume-density" // compact
        static let bubbleSidebar = "plume-bubble-sidebar" // chat bubble only
    }

    /// Compact conversation/message density (only active when Compact is on).
    /// Padding only — the former `min-height` on every gridcell was dropped: a
    /// forced height on rows of a virtualised list fights its own measurement.
    /// Chat-bubble only: hide Messenger's conversation list so the panel shows
    /// just the open thread. Needed for the bubble's privacy goal — at narrow
    /// widths Messenger only collapses the sidebar to an icon rail that still
    /// shows contact avatars. One rule, and `[role="navigation"]` matches a
    /// handful of nodes, so it stays within the performance rule above.
    static let hideSidebarCSS = """
    [role="navigation"] { display: none !important; }
    """

    static let densityCSS = """
    [role="grid"] [role="row"] { padding-top: 2px; padding-bottom: 2px; }
    [role="main"] [role="row"] [dir="auto"] > span { padding-top: 5px; padding-bottom: 5px; }
    """

    // Removed for performance: the indigo accent layer and the code-block
    // styling. Both were decorative, and both keyed on the elements Messenger
    // churns hardest while paginating — the accent matched every icon SVG
    // (walking ancestors per match) and every grid row, and put inherited
    // custom properties on :root. Together with the old universal scrollbar
    // rules they made old-message loading crawl. See the note on StyleID
    // before adding anything back here.
}
