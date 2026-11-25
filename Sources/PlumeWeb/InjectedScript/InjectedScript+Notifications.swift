import Foundation

extension InjectedScript {
    /// Which notification owns the banner of each tag. Native code keys a
    /// tagged banner on the tag alone (`NotificationID.identifier`), so a newer
    /// notification for the same conversation replaces the older banner; the
    /// older one's close() must then do nothing, as in the Notifications
    /// spec, or it takes the newer banner down. No DOM in here, so the tests
    /// run it in a bare JSContext.
    public static let notifyTagsJS = #"""
    (function (g) {
        var MAX = 500;   // the page may never call close()
        g.__plumeNotifyTags = function () {
            var owners = new Map();   // tag -> id of the notification showing it
            return {
                shown: function (tag, id) {
                    var key = String(tag || "");
                    if (!key) return;
                    // Re-inserted, so Map order is least recently shown first.
                    owners.delete(key);
                    owners.set(key, id);
                    while (owners.size > MAX) owners.delete(owners.keys().next().value);
                },
                // A tag no longer in the table closes as it always did.
                closes: function (tag, id) {
                    var key = String(tag || "");
                    if (!key) return true;
                    var owner = owners.get(key);
                    if (owner !== undefined && owner !== id) return false;
                    owners.delete(key);
                    return true;
                }
            };
        };
    })(typeof window !== "undefined" ? window : this);
    """#

    /// Reroutes the web `Notification` API to native macOS notifications and
    /// lets a native click reopen the right thread.
    static let notificationBridgeJS = #"""
        // --- Native notification bridge --------------------------------
        const live = new Map();   // id -> Notification instance
        const MAX_LIVE = 500;     // cap so a long session can't grow this forever
        const tags = window.__plumeNotifyTags();
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
            tags.shown(this.tag, id);
            post("notify", {
                id: id,
                title: String(title || ""),
                body: String(this.body || ""),
                // Native keys the banner on it, so a newer notification for
                // the same thread replaces the last one (and close() finds it).
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
            // A newer notification with this tag owns the banner now.
            if (!tags.closes(this.tag, this._id)) return;
            post("notifyClose", { id: this._id, tag: String(this.tag || "") });
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

    """#
}
