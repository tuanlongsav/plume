import Foundation

/// JavaScript injected at document start into the Messenger page.
///
/// It reroutes the web `Notification` API to native macOS notifications
/// (so they look and behave like a real app, and survive the page being
/// in the background), and lets a native click reopen the right thread.
enum InjectedScript {
    /// Shared theatre detector. Photo/video lightbox only — not emoji,
    /// sticker, GIF or reaction pickers. Those are also `role="dialog"` and
    /// used to trip the greedy size check, which expanded the card to fill
    /// the display then restored it 0.2s later in a loop.
    static let theaterDetectJS = #"""
    (function (g) {
    g.__plumeIsPhotoTheater = function (info) {
        try {
        var W = Number(info.vw) || 0, H = Number(info.vh) || 0;
        var dw = Number(info.dw) || 0, dh = Number(info.dh) || 0;
        var largeMedia = Number(info.largeMedia) || 0;
        var smallImgs = Number(info.smallImgs) || 0;
        if (W < 200 || H < 200) return false;

        function norm(s) {
            s = String(s || "");
            try {
                s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
            } catch (e) {}
            return s.replace(/[\u0111\u0110]/g, "d")
                .replace(/\s+/g, " ").trim().toLowerCase();
        }
        function hasPhrase(n, phrase) {
            var p = n.indexOf(phrase);
            if (p < 0) return false;
            var before = p === 0 || n.charAt(p - 1) === " ";
            var after = p + phrase.length === n.length || n.charAt(p + phrase.length) === " ";
            return before && after;
        }
        var n = norm(info.label);
        var picker = [
            "emoji", "emojis", "sticker", "stickers", "gif", "gifs",
            "bieu tuong", "cam xuc", "nhan dan", "reaction", "reactions",
            "bay to cam xuc", "choose an emoji", "choose a sticker"
        ];
        for (var i = 0; i < picker.length; i++) {
            if (hasPhrase(n, picker[i])) return false;
        }
        // Emoji/sticker grid: lots of tiles, no photograph.
        if (smallImgs >= 8 && largeMedia < 1) return false;

        var covers = dw >= W * 0.62 && dh >= H * 0.48;
        if (covers && largeMedia > 0) return true;
        if (largeMedia > 0 && dw >= W * 0.45 && dh >= H * 0.40) return true;
        return false;
        } catch (e) { return false; }
    };

    // Polled about four times a second while the card shows a thread, and a
    // full pass measures every image and walks computed styles. While nothing
    // a lightbox would add has changed since the last "no", answer from that;
    // every fifth poll measures anyway, in case one opened in place. A "yes"
    // is never reused, so closing the lightbox is seen on the next poll.
    g.__plumeDetectTheater = function () {
        try {
            var sig = location.href + "|" + document.getElementsByTagName("img").length +
                "|" + document.getElementsByTagName("video").length + "|" +
                document.querySelectorAll('[role="dialog"], [role="alertdialog"], [aria-modal="true"]').length;
            var memo = g.__plumeTheaterMemo || (g.__plumeTheaterMemo = { sig: "", skips: 0 });
            if (sig === memo.sig && memo.skips < 4) { memo.skips++; return false; }
            var open = detectTheater();
            memo.sig = open ? "" : sig;
            memo.skips = 0;
            return open;
        } catch (e) { return false; }
    };

    function detectTheater() {
        try {
            var W = window.innerWidth || 0, H = window.innerHeight || 0;
            if (W < 200 || H < 200) return false;

            function labelOf(el) {
                var s = "";
                try { s += " " + (el.getAttribute("aria-label") || ""); } catch (e) {}
                try {
                    var id = el.getAttribute("aria-labelledby");
                    if (id) {
                        var ids = String(id).split(/\s+/);
                        for (var i = 0; i < ids.length; i++) {
                            var node = document.getElementById(ids[i]);
                            if (node) s += " " + (node.innerText || node.textContent || "");
                        }
                    }
                } catch (e) {}
                try {
                    var h = el.querySelector("h1, h2, [role='heading']");
                    if (h) s += " " + (h.innerText || h.textContent || "");
                } catch (e) {}
                return s;
            }
            function metrics(el) {
                var r = el.getBoundingClientRect();
                var large = 0, small = 0;
                try {
                    var media = el.querySelectorAll("img, video");
                    var cap = Math.min(media.length, 60);
                    for (var i = 0; i < cap; i++) {
                        var mr = media[i].getBoundingClientRect();
                        if (mr.width < 8 || mr.height < 8) continue;
                        if (mr.width >= 220 && mr.height >= 180) large++;
                        else if (mr.width <= 96 && mr.height <= 96) small++;
                    }
                } catch (e) {}
                return {
                    vw: W, vh: H, dw: r.width, dh: r.height,
                    label: labelOf(el), largeMedia: large, smallImgs: small
                };
            }
            var nodes = document.querySelectorAll(
                '[role="dialog"], [role="alertdialog"], [aria-modal="true"]');
            for (var i = 0; i < nodes.length; i++) {
                if (g.__plumeIsPhotoTheater(metrics(nodes[i]))) return true;
            }
            var media = document.querySelectorAll("img, video");
            for (var m = 0; m < media.length; m++) {
                var el = media[m];
                var r = el.getBoundingClientRect();
                if (r.width < 220 || r.height < 180) continue;
                var n = el;
                for (var d = 0; d < 12 && n; d++) {
                    var cs;
                    try { cs = window.getComputedStyle(n); } catch (e) { break; }
                    if (cs.visibility === "hidden" || cs.display === "none") break;
                    var role = "";
                    try { role = n.getAttribute("role") || ""; } catch (e) {}
                    var modal = false;
                    try { modal = n.getAttribute("aria-modal") === "true"; } catch (e) {}
                    if (cs.position === "fixed" || cs.position === "sticky"
                            || role === "dialog" || role === "alertdialog" || modal) {
                        if (g.__plumeIsPhotoTheater(metrics(n))) return true;
                        break;
                    }
                    n = n.parentElement;
                }
            }
            return false;
        } catch (e) { return false; }
    }
    })(typeof window !== "undefined" ? window : globalThis);
    """#

    /// Label matching for the delete-chat flow. No DOM in here, so the tests
    /// can run it in a bare JSContext. Exact (accent-folded) labels only: a
    /// destructive flow must never click something that merely looks close.
    static let deleteMatchJS = #"""
    (function (g) {
        function norm(s) {
            s = String(s || "");
            try { s = s.normalize("NFD").replace(/[̀-ͯ]/g, ""); } catch (e) {}
            return s.replace(/[đĐ]/g, "d")
                .replace(/\s+/g, " ").trim().toLowerCase();
        }
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
    static let deleteThreadJS = deleteMatchJS + #"""
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
        var lines = (el.innerText || el.textContent || "").split("\n")
            .map(function (x) { return x.trim(); }).filter(Boolean);
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
        var rows = document.querySelectorAll('[role="row"]');
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].closest('[role="main"]')) continue;   // skip the open thread
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
            // Rewriting identical text still re-parses the sheet and restyles
            // the whole document — and this runs on every thread open.
            if (el.textContent !== css) el.textContent = css;
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

    """# + threadHelpersJS + #"""

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

        // Removed: the card's overlay-fitting pass. It re-fit every
        // position:fixed layer into a clipped strip, driven by a document-wide
        // MutationObserver. The clip has been 0 since chrome became CSS-hidden,
        // so it only ever ran its clear branch — and that rewrote <html>'s class
        // attribute, re-fired the observer and scheduled another frame, forever.

    """# + theaterDetectJS + #"""

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
                        var t = (r.innerText || r.textContent || "").split("\n")
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

        // Nudge Messenger's virtualised inbox so older threads enter the DOM
        // before the next `__plumeConvList` snapshot. Returns true when the
        // scroll position actually moved (more history may still be available).
        window.__plumeExpandConvList = function () {
            try {
                var rows = document.querySelectorAll('[role="row"]');
                var seed = null;
                for (var i = 0; i < rows.length; i++) {
                    if (rows[i].closest('[role="main"]')) continue;
                    if (rows[i].querySelector('a[role="link"][href*="/t/"]')) {
                        seed = rows[i]; break;
                    }
                }
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

        // --- Right-click a sidebar row → native menu (delete chat) ------
        // Only rows of the conversation list; a right-click anywhere else
        // keeps WebKit's own menu.
        document.addEventListener("contextmenu", function (e) {
            try {
                var row = e.target && e.target.closest && e.target.closest('[role="row"]');
                if (!row || row.closest('[role="main"]')) return;
                var link = row.querySelector('a[role="link"][href]');
                if (!link || link.href.indexOf('/t/') === -1) return;
                var name = (row.innerText || row.textContent || "").split("\n")
                    .map(function (x) { return x.trim(); }).filter(Boolean)[0]
                    || (link.getAttribute('aria-label') || '').split(',')[0];
                e.preventDefault();
                e.stopPropagation();
                post("rowMenu", { href: link.href, name: String(name).trim().slice(0, 60) });
            } catch (err) {}
        }, true);

        // Note: the unread badge is derived natively by observing WKWebView's
        // `title` (a public, injection-independent signal), so there is no
        // badge bridge here.
    })();
    """#

    /// Opening threads and scrolling the bubble card. Part of `source`, and
    /// also evaluated on the live page before each `showThread`: user scripts
    /// only run at document start, so a Messenger session that was already
    /// open would otherwise keep older helpers. One copy, so the two cannot
    /// drift apart.
    static let threadHelpersJS = #"""
    // --- Open a thread without reloading (chat bubble card) --------
    // The card keeps one long-lived web view, so switching bubbles must not
    // reload messenger.com — that rebuilds the entire SPA, and the empty
    // inbox snapshot that follows deletes every contact bubble. Click the
    // conversation row. If the row is gone, return false: native code must
    // NOT fall back to load().
    window.__plumeOpenThread = function (href, force) {
        try {
            function id(u) {
                var p = String(u || "").split("?")[0].replace(/\/+$/, "").split("/");
                return p[p.length - 1] || "";
            }
            var want = id(href);
            if (!want) return false;
            // Already on this thread: a plain no-op leaves a detached/resized
            // card stuck on old virtualised history. `force` re-clicks the
            // row so Messenger remounts the latest messages.
            if (id(location.href) === want && !force) return true;
            var links = document.querySelectorAll('a[href*="/t/"]');
            for (var i = 0; i < links.length; i++) {
                if (id(links[i].href) !== want) continue;
                var hit = links[i].querySelector('[role="gridcell"]') || links[i];
                hit.click();
                return true;
            }
        } catch (e) {}
        return false;
    };

    // Switching heads while the card is open: the card stylesheet has hidden
    // the inbox since the previous open, and Messenger's virtualised list can
    // drop rows it cannot lay out, so the row to click may be gone. Unhide
    // the inbox (the rules are scoped to this class) and retry a few times
    // while it remounts — a bounded ladder that ends by itself, never a
    // standing loop. Native code re-applies the class once this settles.
    window.__plumeOpenThreadRetry = function (href, force) {
        if (window.__plumeOpenThread(href, force)) return Promise.resolve(true);
        var root = document.documentElement;
        if (!root.classList.contains("plume-card-thread")) return Promise.resolve(false);
        root.classList.remove("plume-card-thread");
        return new Promise(function (resolve) {
            var tries = 0;
            (function again() {
                if (window.__plumeOpenThread(href, force)) return resolve(true);
                if (++tries >= 8) return resolve(false);
                setTimeout(again, 80);
            })();
        });
    };

    // --- Jump to the newest message (chat bubble card) -------------
    // Returns "settled" when the conversation was already at its newest
    // message and there was nothing to jump, so native code can stop its
    // retry ladder early instead of re-scanning the page.
    window.__plumeScrollToLatest = function () {
        try {
            var main = document.querySelector('[role="main"]');
            if (!main) return false;
            var phrases = [
                "jump to present", "tin nhan moi", "tin nhắn mới",
                "new message", "new messages", "xem tin nhan moi",
                "xem tin nhắn mới", "nhay den hien tai", "nhảy đến hiện tại"
            ];
            function norm(s) {
                return String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "")
                    .replace(/[đĐ]/g, "d")
                    .replace(/\s+/g, " ").trim().toLowerCase();
            }
            var jumped = false;
            var controls = main.querySelectorAll('[role="button"], button, a[role="link"]');
            for (var c = 0; c < controls.length; c++) {
                var label = norm(controls[c].innerText || controls[c].getAttribute("aria-label"));
                if (!label || label.length > 48) continue;
                for (var p = 0; p < phrases.length; p++) {
                    if (label.indexOf(phrases[p]) >= 0) {
                        controls[c].click();
                        jumped = true;
                        break;
                    }
                }
            }
            // The scroller found last time is reused while it is still in
            // this thread: finding it means a computed-style read of every
            // div in the conversation.
            var best = window.__plumeScroller;
            if (!(best && best.isConnected && main.contains(best)
                  && best.scrollHeight - best.clientHeight > 80)) {
                best = null;
                var bestOver = 80;
                var all = main.querySelectorAll("div");
                for (var i = 0; i < all.length; i++) {
                    var e = all[i];
                    var over = e.scrollHeight - e.clientHeight;
                    if (over <= bestOver) continue;
                    var oy = window.getComputedStyle(e).overflowY;
                    if (oy !== "auto" && oy !== "scroll" && oy !== "overlay") continue;
                    best = e; bestOver = over;
                }
                window.__plumeScroller = best;
            }
            if (!best) return false;
            var atEnd = best.scrollHeight - best.scrollTop - best.clientHeight <= 2;
            for (var n = 0; n < 5; n++) best.scrollTop = best.scrollHeight;
            var rows = main.querySelectorAll('[role="row"], [role="gridcell"]');
            if (rows.length) {
                rows[rows.length - 1].scrollIntoView({ block: "end", inline: "nearest" });
            }
            best.scrollTop = best.scrollHeight;
            return atEnd && !jumped ? "settled" : true;
        } catch (e) { return false; }
    };
    """#

    /// Escape a Swift string for safe interpolation into evaluated JavaScript.
    static func stringLiteral(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

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
        static let cardThread = "plume-card-thread"
    }

    /// Compact conversation/message density (only active when Compact is on).
    /// Padding only — the former `min-height` on every gridcell was dropped: a
    /// forced height on rows of a virtualised list fights its own measurement.
    static let densityCSS = """
    [role="grid"] [role="row"] { padding-top: 2px; padding-bottom: 2px; }
    [role="main"] [role="row"] [dir="auto"] > span { padding-top: 5px; padding-bottom: 5px; }
    """

    /// Hide Messenger chrome inside the bubble card. Caprine (issue 1718) and
    /// every other messenger.com wrapper hit the same wall: below ~900px the
    /// conversation is removed from the DOM, so a narrow clipped webview can
    /// never host theatre/forward overlays. The card itself must be that wide;
    /// these rules only hide the leftover sidebar columns.
    static let cardThreadCSS = """
    html.plume-card-thread [role="navigation"]:not(:has([role="main"])) {
      display: none !important;
      width: 0 !important;
      min-width: 0 !important;
      max-width: 0 !important;
      flex: 0 0 0 !important;
      overflow: hidden !important;
      pointer-events: none !important;
    }
    html.plume-card-thread [role="main"] {
      width: 100% !important;
      max-width: none !important;
      flex: 1 1 auto !important;
      min-width: 0 !important;
    }
    """

    // Removed for performance: the indigo accent layer and the code-block
    // styling. Both were decorative, and both keyed on the elements Messenger
    // churns hardest while paginating — the accent matched every icon SVG
    // (walking ancestors per match) and every grid row, and put inherited
    // custom properties on :root. Together with the old universal scrollbar
    // rules they made old-message loading crawl. See the note on StyleID
    // before adding anything back here.
}
