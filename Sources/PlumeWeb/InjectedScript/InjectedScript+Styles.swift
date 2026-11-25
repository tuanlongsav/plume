import Foundation

extension InjectedScript {
    /// Style-tag helpers invoked by native code to toggle tầng-B CSS layers.
    static let styleInjectionJS = #"""
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
    public enum StyleID {
        public static let density = "plume-density" // compact
        public static let cardThread = "plume-card-thread"
    }

    /// Compact conversation/message density (only active when Compact is on).
    /// Padding only — the former `min-height` on every gridcell was dropped: a
    /// forced height on rows of a virtualised list fights its own measurement.
    public static let densityCSS = """
    [role="grid"] [role="row"] { padding-top: 2px; padding-bottom: 2px; }
    [role="main"] [role="row"] [dir="auto"] > span { padding-top: 5px; padding-bottom: 5px; }
    """

    /// Hide Messenger chrome inside the bubble card. Caprine (issue 1718) and
    /// every other messenger.com wrapper hit the same wall: below ~900px the
    /// conversation is removed from the DOM, so a narrow clipped webview can
    /// never host theatre/forward overlays. The card itself must be that wide;
    /// these rules only hide the leftover sidebar columns.
    ///
    /// On facebook.com/messages the page also carries Facebook's top bar
    /// (`[role=banner]`) and reserves its height through `--header-height`,
    /// which Facebook declares on `html` and on its theme classes
    /// (`__fb-light-mode` / `__fb-dark-mode`, stable names, not hashed ones).
    /// Hiding the bar alone would leave a blank band. Each concern is a rule of
    /// its own, so a selector one engine rejects cannot take the others down.
    /// The variables differ from the custom properties the performance note
    /// warns about: they sit on `html` and two theme roots, not on every node,
    /// and change only when the card toggles this class. While
    /// `__plumeOpenThreadRetry` lifts the class the bar briefly shows; that is
    /// accepted.
    public static let cardThreadCSS = """
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
    html.plume-card-thread [role="banner"]:not([role="main"] *) {
      display: none !important;
    }
    html.plume-card-thread,
    html.plume-card-thread .__fb-light-mode,
    html.plume-card-thread .__fb-dark-mode {
      --header-height: 0px !important;
      --messenger-card-spacing: 0px !important;
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
