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
    }

    /// Thin scrollbars, softer chat bubbles — applied on every load.
    /// ⚠️ Messenger uses hashed class names; selectors here lean on stable
    /// role/attr hooks and must be verified against the live DOM before ship.
    static let baseCSS = """
    *::-webkit-scrollbar { width: 8px; height: 8px; }
    *::-webkit-scrollbar-thumb { background: rgba(140,140,150,.4); border-radius: 8px; }
    *::-webkit-scrollbar-track { background: transparent; }
    [role="row"] [dir="auto"] > span { border-radius: 18px !important; box-shadow: 0 1px 1px rgba(0,0,0,.08); }
    """

    /// Compact conversation/message density.
    static let densityCSS = """
    [role="grid"] [role="row"] { padding-top: 2px; padding-bottom: 2px; }
    [role="row"] [role="gridcell"] { min-height: 52px; }
    [role="row"] [dir="auto"] > span { padding-top: 5px; padding-bottom: 5px; }
    """

    /// Restrained Plume indigo accent.
    static let accentCSS = """
    :root { --plume-accent: #4F46E5; --plume-accent-2: #4338CA; }
    div[role="button"][aria-label] svg[aria-hidden="true"] { color: var(--plume-accent); }
    [role="grid"] [role="row"][aria-selected="true"] { box-shadow: inset 3px 0 0 var(--plume-accent); }
    a[role="link"]:hover { color: var(--plume-accent); }
    """
}
