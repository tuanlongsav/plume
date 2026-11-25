import Foundation

extension InjectedScript {
    /// Opening threads and scrolling the bubble card. Part of `source`, and
    /// also evaluated on the live page before each `showThread`: user scripts
    /// only run at document start, so a Messenger session that was already
    /// open would otherwise keep older helpers. One copy, so the two cannot
    /// drift apart.
    public static let threadHelpersJS = InjectedScript.listRowsJS + #"""
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
            // The chat list's row; Facebook's top-bar popover and links
            // inside a message are not the list, and clicking one there opens
            // a mini chat or a profile instead of routing the page.
            var rows = plumeListRows();
            for (var i = 0; i < rows.length; i++) {
                var link = rows[i].querySelector('a[role="link"][href]');
                if (!link || id(link.href) !== want) continue;
                var hit = link.querySelector('[role="gridcell"]') || link;
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
            // Labels pass through norm() and are matched by substring, so
            // accent-free stems cover the accented and plural variants.
            var phrases = ["jump to present", "nhay den hien tai", "new message", "tin nhan moi"];
            \#(InjectedScript.normJS)
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

    /// Hides Messenger's focus-revealed "skip to main content" anchor inside the
    /// narrow bubble card viewport.
    static let hideSkipLinksJS = #"""
        // --- Skip link (chat bubble card) ------------------------------
        // Messenger's "skip to main content" anchor is revealed on focus and
        // sits over the conversation in a card-sized viewport. Matched by its
        // accessible text rather than a class, and only among in-page anchors,
        // so nothing else can be caught by it.
        window.__plumeHideSkipLinks = function () {
            var phrases = ["chuyen den noi dung chinh", "skip to main content",
                           "chuyen toi noi dung chinh"];
            \#(InjectedScript.normJS)
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

    """#

    /// Shared theatre detector. Photo/video lightbox only — not emoji,
    /// sticker, GIF or reaction pickers. Those are also `role="dialog"` and
    /// used to trip the greedy size check, which expanded the card to fill
    /// the display then restored it 0.2s later in a loop.
    public static let theaterDetectJS = #"""
    (function (g) {
    g.__plumeIsPhotoTheater = function (info) {
        try {
        var W = Number(info.vw) || 0, H = Number(info.vh) || 0;
        var dw = Number(info.dw) || 0, dh = Number(info.dh) || 0;
        var largeMedia = Number(info.largeMedia) || 0;
        var smallImgs = Number(info.smallImgs) || 0;
        if (W < 200 || H < 200) return false;

        \#(InjectedScript.normJS)
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
}
