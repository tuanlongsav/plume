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

        // --- Open a thread without reloading (chat bubble card) --------
        // The card keeps one long-lived web view, so switching bubbles must not
        // reload messenger.com — that rebuilds the entire SPA and takes
        // seconds. Clicking the conversation's own row is the same transition
        // the user would make by hand, and it is instant. The row is in the DOM
        // even though the card clips the list out of sight.
        window.__plumeOpenThread = function (href) {
            try {
                function id(u) {
                    var p = String(u || "").split("?")[0].replace(/\/+$/, "").split("/");
                    return p[p.length - 1] || "";
                }
                var want = id(href);
                if (!want) return false;
                if (id(location.href) === want) return true;      // already there
                var links = document.querySelectorAll('a[role="link"][href*="/t/"]');
                for (var i = 0; i < links.length; i++) {
                    if (id(links[i].href) !== want) continue;
                    var hit = links[i].querySelector('[role="gridcell"]') || links[i];
                    hit.click();
                    return true;
                }
            } catch (e) {}
            return false;
        };

        // --- Jump to the newest message (chat bubble card) -------------
        // The shared web view is resized when it moves into the card, and a
        // virtualised message list keeps its scroll offset across that — which
        // lands the reader in old history instead of at the latest message.
        // Called only just after a thread switch, never while reading, so it
        // cannot fight someone scrolling back through the conversation.
        window.__plumeScrollToLatest = function () {
            try {
                var main = document.querySelector('[role="main"]');
                if (!main) return false;
                var best = null, bestOver = 120;
                var all = main.querySelectorAll('div');
                for (var i = 0; i < all.length; i++) {
                    var e = all[i];
                    var over = e.scrollHeight - e.clientHeight;
                    if (over <= bestOver) continue;
                    var oy = window.getComputedStyle(e).overflowY;
                    if (oy !== 'auto' && oy !== 'scroll') continue;
                    best = e; bestOver = over;
                }
                if (!best) return false;
                best.scrollTop = best.scrollHeight;
                return true;
            } catch (e) { return false; }
        };

        // --- Skip link (chat bubble card) ------------------------------
        // Messenger's "skip to main content" anchor is revealed on focus and
        // sits over the conversation in a card-sized viewport. Matched by its
        // accessible text rather than a class, and only among in-page anchors,
        // so nothing else can be caught by it.
        window.__plumeHideSkipLinks = function () {
            var phrases = ["chuyen den noi dung chinh", "skip to main content",
                           "chuyen toi noi dung chinh"];
            function norm(s) {
                // đ/Đ (U+0111/U+0110) have NO canonical decomposition, so NFD
                // leaves them intact and a plain-ASCII phrase list never
                // matched the Vietnamese label. Fold them by hand.
                return String(s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "")
                    .replace(/[\u0111\u0110]/g, "d")
                    .replace(/\s+/g, " ").trim().toLowerCase();
            }
            var n = 0;
            try {
                var links = document.querySelectorAll('a[href^="#"], a[href=""], [role="link"][href^="#"]');
                for (var i = 0; i < links.length; i++) {
                    var t = norm(links[i].innerText || links[i].textContent);
                    if (phrases.indexOf(t) >= 0) {
                        links[i].style.setProperty("display", "none", "important");
                        n++;
                    }
                }
            } catch (e) {}
            return n;
        };

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
                var rows = document.querySelectorAll('[role="row"]');
                for (var i = 0; i < rows.length && out.length < limit; i++) {
                    var r = rows[i];
                    if (r.closest('[role="main"]')) continue;   // skip the open thread
                    var link = r.querySelector('a[role="link"][href]');
                    if (!link || link.href.indexOf('/t/') === -1) continue;
                    var img = r.querySelector('img');
                    // Read the row's own lines rather than slicing the
                    // aria-label at its first comma: a group thread is named
                    // "An, Bình, Chi", so that split named the bubble "An" and
                    // left the rest of the group's name standing in for the
                    // last message.
                    var label = "", preview = "", time = "";
                    try {
                        var t = (r.innerText || "").split("\n")
                                 .map(function (x) { return x.trim(); })
                                 .filter(Boolean);
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

                    // Unread. The accessible label carries it in some locales
                    // and not others — on a Vietnamese UI it never appears, so
                    // this also reads the styling Messenger actually uses: an
                    // unread row's preview line is rendered semibold, a read
                    // one regular.
                    var unread = !!r.querySelector(
                        '[aria-label*="unread" i], [aria-label*="chưa đọc" i]');
                    if (!unread && preview) {
                        try {
                            var probe = preview.slice(0, 12);
                            var nodes = r.querySelectorAll('[dir="auto"], span');
                            for (var q = 0; q < nodes.length; q++) {
                                var txt = (nodes[q].textContent || "").trim();
                                if (!txt || txt.indexOf(probe) !== 0) continue;
                                var fw = parseInt(
                                    window.getComputedStyle(nodes[q]).fontWeight, 10) || 400;
                                if (fw >= 600) unread = true;
                                break;
                            }
                        } catch (e) {}
                    }
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
    }

    /// Compact conversation/message density (only active when Compact is on).
    /// Padding only — the former `min-height` on every gridcell was dropped: a
    /// forced height on rows of a virtualised list fights its own measurement.
    ///
    /// There is deliberately no rule here for the chat-bubble card. Hiding
    /// Messenger's sidebar with CSS cannot work: the page reserves the icon
    /// rail (44pt) and the conversation list (356pt) first and gives the
    /// conversation only what is left, so at a card-sized viewport
    /// `[role="main"]` measures 0pt tall and there is nothing left to reveal.
    /// The card gives the page a wide viewport and clips the chrome instead.
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
