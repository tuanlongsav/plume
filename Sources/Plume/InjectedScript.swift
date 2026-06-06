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
            post("notify", {
                id: id,
                title: String(title || ""),
                body: String(this.body || ""),
                icon: String(this.icon || ""),
                tag: String(this.tag || "")
            });
            if (typeof this.onshow === "function") {
                try { this.onshow(); } catch (e) {}
            }
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

        // --- Unread badge --------------------------------------------
        // Messenger encodes unread count in document.title, e.g. "(3) Messenger".
        function reportBadge() {
            const m = /\((\d+)\)/.exec(document.title || "");
            post("badge", { count: m ? parseInt(m[1], 10) : 0 });
        }
        const titleObserver = new MutationObserver(reportBadge);
        function startTitleObserver() {
            const el = document.querySelector("title");
            if (el) titleObserver.observe(el, { childList: true });
            reportBadge();
        }
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", startTitleObserver);
        } else {
            startTitleObserver();
        }
    })();
    """#
}
