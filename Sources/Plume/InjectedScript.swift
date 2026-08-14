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
                    var i = selectedIndex(); if (i < 0) i = 0;
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
    enum StyleID {
        static let base = "plume-base"       // always on (scrollbar + soft bubbles)
        static let density = "plume-density" // compact
        static let accent = "plume-accent"   // Plume indigo accent
        static let code = "plume-code"       // code-block styling
    }

    /// Thin scrollbars, softer chat bubbles — applied on every load.
    /// ⚠️ Messenger uses hashed class names; selectors here lean on stable
    /// role/attr hooks and must be verified against the live DOM before ship.
    /// Bubble styling is scoped to the open thread (`[role="main"]`) so it can't
    /// bleed into the conversation-list preview rows (which also use
    /// `[role="row"] [dir="auto"] > span`).
    static let baseCSS = """
    *::-webkit-scrollbar { width: 12px; height: 12px; }
    *::-webkit-scrollbar-thumb {
        background: transparent;
        box-shadow: inset 0 0 12px 12px rgba(140,140,150,.45);
        border: solid 3px transparent; border-radius: 8px;
    }
    *::-webkit-scrollbar-track { background: transparent; }
    *::-webkit-scrollbar-track:hover { box-shadow: inset 0 0 12px 12px rgba(140,140,150,.10); }
    @media (prefers-color-scheme: dark) {
        *::-webkit-scrollbar-thumb { box-shadow: inset 0 0 12px 12px rgba(255,255,255,.30); }
        *::-webkit-scrollbar-track:hover { box-shadow: inset 0 0 12px 12px rgba(255,255,255,.06); }
    }
    [role="main"] [role="row"] [dir="auto"] > span { border-radius: 18px !important; box-shadow: 0 1px 1px rgba(0,0,0,.08); }
    """

    /// Compact conversation/message density. Bubble padding is scoped to the
    /// open thread; the row/cell tightening stays broad (it is meant to make
    /// the conversation list denser) but is only active when Compact is on.
    static let densityCSS = """
    [role="grid"] [role="row"] { padding-top: 2px; padding-bottom: 2px; }
    [role="row"] [role="gridcell"] { min-height: 52px; }
    [role="main"] [role="row"] [dir="auto"] > span { padding-top: 5px; padding-bottom: 5px; }
    """

    /// Restrained Plume indigo accent.
    static let accentCSS = """
    :root { --plume-accent: #4F46E5; --plume-accent-2: #4338CA; }
    div[role="button"][aria-label] svg[aria-hidden="true"] { color: var(--plume-accent); }
    [role="grid"] [role="row"][aria-selected="true"] { box-shadow: inset 3px 0 0 var(--plume-accent); }
    a[role="link"]:hover { color: var(--plume-accent); }
    """

    /// Code blocks — Tomorrow (light) / Tomorrow-Night (dark) palette, adapted
    /// from Caprine (MIT © Sindre Sorhus). Keyed on semantic <pre>/<code> tags,
    /// scoped to the open thread; the .token.* colours are inert unless
    /// Messenger ships a syntax highlighter.
    static let codeCSS = """
    [role="main"] pre, [role="main"] code {
        font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
        font-size: 12.5px;
    }
    [role="main"] pre {
        background: rgba(0,0,0,.04) !important;
        border: 1px solid rgba(0,0,0,.10) !important;
        border-radius: 8px !important; padding: 10px 12px !important;
        color: #1d1f21 !important; overflow-x: auto;
    }
    [role="main"] :not(pre) > code {
        background: rgba(0,0,0,.06) !important; border-radius: 4px;
        padding: 1px 5px !important; color: #1d1f21 !important;
    }
    [role="main"] pre .token.comment, [role="main"] pre .token.prolog { color:#969896 !important; }
    [role="main"] pre .token.keyword, [role="main"] pre .token.important { color:#b294bb !important; }
    [role="main"] pre .token.function { color:#81a2be !important; }
    [role="main"] pre .token.string, [role="main"] pre .token.char { color:#b5bd68 !important; }
    [role="main"] pre .token.number, [role="main"] pre .token.boolean, [role="main"] pre .token.constant { color:#de935f !important; }
    [role="main"] pre .token.tag { color:#a3685a !important; }
    [role="main"] pre .token.attr-name, [role="main"] pre .token.variable { color:#cc6666 !important; }
    [role="main"] pre .token.attr-value { color:#139543 !important; }
    @media (prefers-color-scheme: dark) {
        [role="main"] pre {
            background: rgba(255,255,255,.05) !important;
            border-color: rgba(255,255,255,.10) !important; color: #c5c8c6 !important;
        }
        [role="main"] :not(pre) > code {
            background: rgba(255,255,255,.08) !important; color: #c5c8c6 !important;
        }
    }
    """
}
