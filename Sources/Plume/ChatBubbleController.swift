import AppKit
import WebKit

extension Notification.Name {
    /// Posted whenever the unread count changes, so the bubble can badge itself
    /// without doing any DOM work of its own.
    static let plumeUnreadChanged = Notification.Name("plume.unreadChanged")
}


// MARK: - Panels

/// The expanded chat card. Uses `.titled` + `.fullSizeContentView` rather than
/// `.borderless`: that buys system rounded corners, shadow, resizing and a
/// draggable titlebar strip for free. (A WKWebView swallows mouse events, so
/// `isMovableByWindowBackground` does nothing on a borderless window — we'd
/// have to hand-roll dragging and shadow invalidation.)
final class BubbleCardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable,
                                .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true              // ⇒ level == .floating
        hidesOnDeactivate = false           // NSPanel defaults to true
        canHide = false                     // survive Cmd+H / Hide Others
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        title = "Plume"                     // never the contact's name
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        minSize = NSSize(width: 340, height: 420)
        sharingType = .none                 // keep it out of screen shares/recordings
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Esc collapses back to the bubble.
    override func cancelOperation(_ sender: Any?) {
        (delegate as? ChatBubbleController)?.collapse()
    }
}

/// The collapsed bubble. Borderless and circular; deliberately contains no web
/// view, so nothing private can be on screen while collapsed.
final class BubblePanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        title = "Plume"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        sharingType = .none
    }
    override var canBecomeKey: Bool { true }   // borderless windows say false
    override var canBecomeMain: Bool { false }
}

// MARK: - Bubble content

/// What the collapsed bubble shows: the Plume feather and an unread count.
/// Deliberately no avatar and no contact name — showing who you're talking to
/// would defeat the point of collapsing for privacy.
final class BubbleView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private let gradient = CAGradientLayer()
    private let feather = FeatherView(variant: .mono, monoColor: .white)
    private let badge = NSTextField(labelWithString: "")
    private let badgeBack = NSView()

    var unread: Int = 0 { didSet { refreshBadge() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = frameRect.width / 2

        gradient.frame = bounds
        gradient.colors = Theme.gradientColors      // Plume blue -> indigo
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)

        feather.translatesAutoresizingMaskIntoConstraints = false
        addSubview(feather)

        badgeBack.wantsLayer = true
        badgeBack.layer?.cornerRadius = 9
        badgeBack.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeBack.translatesAutoresizingMaskIntoConstraints = false
        badgeBack.isHidden = true
        addSubview(badgeBack)

        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBack.addSubview(badge)

        NSLayoutConstraint.activate([
            feather.centerXAnchor.constraint(equalTo: centerXAnchor),
            feather.centerYAnchor.constraint(equalTo: centerYAnchor),
            feather.widthAnchor.constraint(equalToConstant: 22),
            feather.heightAnchor.constraint(equalToConstant: 25),

            badgeBack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badgeBack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            badgeBack.heightAnchor.constraint(equalToConstant: 18),
            badgeBack.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),

            badge.centerXAnchor.constraint(equalTo: badgeBack.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeBack.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: badgeBack.leadingAnchor, constant: 5),
            badge.trailingAnchor.constraint(equalTo: badgeBack.trailingAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        layer?.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    private func refreshBadge() {
        badgeBack.isHidden = unread <= 0
        badge.stringValue = unread > 99 ? "99+" : String(unread)
    }

    // MARK: Click vs drag — one gesture has to do both.

    /// The bubble window is never the key window, and AppKit withholds
    /// mouseDown from views in a non-key window unless they opt in. Without
    /// this, the first (and every) tap on the bubble was swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The feather and badge are decoration: never let them swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    private var mouseDownAt: NSPoint = .zero
    private var windowOriginAtDown: NSPoint = .zero
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = NSEvent.mouseLocation
        windowOriginAtDown = window?.frame.origin ?? .zero
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownAt.x, dy = now.y - mouseDownAt.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: windowOriginAtDown.x + dx,
                                      y: windowOriginAtDown.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { onMoved?() } else { onClick?() }
    }
}

// MARK: - Controller

/// A floating mini-Messenger that collapses to a privacy bubble.
///
/// Two windows rather than one that resizes: a window shrunk to a few pixels
/// still renders and runs timers, so collapsing that way saves nothing and
/// still puts the conversation on screen. Ordering the card out is what lets
/// WebKit throttle it — and pixels that don't exist can't be read over your
/// shoulder.
///
/// The web view itself is created once and kept alive across collapses so new
/// messages keep arriving and expanding is instant; it is only detached from
/// the view hierarchy, which is what releases the rendering cost.
final class ChatBubbleController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {

    static private(set) var shared: ChatBubbleController?
    static var isOpen: Bool { shared != nil }

    /// Called when the user asks to leave bubble mode (mode button in the card).
    var onExitBubbleMode: (() -> Void)?

    /// Enter bubble mode. The caller hides the main window.
    @discardableResult
    static func show(onExit: @escaping () -> Void) -> ChatBubbleController {
        if let existing = shared { return existing }
        let c = ChatBubbleController()
        shared = c
        c.onExitBubbleMode = onExit
        c.showCollapsed()   // establishes the bubble's position
        c.expand()          // ...then open the chat immediately
        return c
    }

    /// Leave bubble mode entirely.
    static func hide() {
        shared?.dismiss()
        shared = nil
    }

    private static let bubbleSize: CGFloat = 56
    private static let cardSize = NSSize(width: 380, height: 540)
    private static let originKey = "plume.bubbleOrigin"

    private let card: BubbleCardPanel
    private let bubble: BubblePanel
    private let bubbleView: BubbleView
    private var webView: WKWebView!
    private var isExpanded = false
    private var hasLoaded = false
    private var collapseWork: DispatchWorkItem?
    private var urlObservation: NSKeyValueObservation?
    private let modeButton = NSButton()

    private override init() {
        card = BubbleCardPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize))
        bubble = BubblePanel(size: Self.bubbleSize)
        bubbleView = BubbleView(frame: NSRect(x: 0, y: 0, width: Self.bubbleSize,
                                              height: Self.bubbleSize))
        super.init()

        bubble.contentView = bubbleView
        card.delegate = self
        bubbleView.onClick = { [weak self] in self?.expand() }
        bubbleView.onMoved = { [weak self] in self?.saveOrigin() }

        buildWebView()
        restoreOrigin()

        NotificationCenter.default.addObserver(
            self, selector: #selector(unreadChanged(_:)),
            name: .plumeUnreadChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Web view

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        // Shares the login session with the main window.
        config.websiteDataStore = .default()

        // Its own content controller: we inject the helper script (for
        // __plumeSetStyle) but register NO message handlers, so this view never
        // raises a second, duplicate native notification for the same message.
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: InjectedScript.source,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        config.userContentController = ucc
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Plume.userAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        webView = wv

        // The sidebar is hidden only once a conversation is open, so the bubble
        // can still show the list for picking someone.
        urlObservation = wv.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.applySidebarVisibility()
        }
    }

    private func installWebView() {
        guard let content = card.contentView, webView.superview !== content else { return }
        content.addSubview(webView)
        installModeButton(in: content)
        NSLayoutConstraint.activate([
            // Leave the titlebar strip free so the card stays draggable and the
            // close button isn't covered by the page.
            webView.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Switch back to the full Plume window, in the card's titlebar strip.
    private func installModeButton(in content: NSView) {
        guard modeButton.superview == nil else { return }
        modeButton.image = NSImage(systemSymbolName: "macwindow",
                                   accessibilityDescription: L.t("Cửa sổ chính", "Main Window"))
        modeButton.toolTip = L.t("Về cửa sổ chính", "Back to the main window")
        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(exitBubbleMode)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(modeButton)
        NSLayoutConstraint.activate([
            modeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            modeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            modeButton.widthAnchor.constraint(equalToConstant: 22),
            modeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func exitBubbleMode() { onExitBubbleMode?() }

    /// Sidebar hiding is DISABLED.
    ///
    /// Injecting `[role="navigation"] { display: none }` blanked the whole
    /// panel: at the card's ~380pt width Messenger switches to its compact
    /// layout and nests the conversation itself inside a navigation landmark,
    /// so the rule hid everything rather than just the list. The narrow width
    /// already collapses the list on its own, so we inject nothing here — and
    /// nothing is the cheapest thing we can inject.
    private func applySidebarVisibility() {
        let id = InjectedScript.StyleID.bubbleSidebar
        guard let idJSON = Self.jsonString(id) else { return }
        webView.evaluateJavaScript("window.__plumeRemoveStyle(\(idJSON))", completionHandler: nil)
    }

    private static func jsonString(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Show / expand / collapse

    private func showCollapsed() {
        isExpanded = false
        card.orderOut(nil)
        bubble.orderFrontRegardless()
    }

    /// Open the card. Loads the inbox on first use so the user can pick who to
    /// talk to; afterwards it reopens exactly where they left off.
    func expand(thread: URL? = nil) {
        collapseWork?.cancel(); collapseWork = nil
        installWebView()
        if let thread {
            webView.load(URLRequest(url: thread))
            hasLoaded = true
        } else if !hasLoaded {
            webView.load(URLRequest(url: Plume.homeURL))
            hasLoaded = true
        }
        positionCardNearBubble()
        isExpanded = true
        bubble.orderOut(nil)
        // A non-activating panel can take keys for typing without pulling Plume
        // in front of whatever app you were using.
        card.makeKeyAndOrderFront(nil)
    }

    /// Back to the bubble: order the card out and detach the web view, which is
    /// what actually lets WebKit stop rendering it. The view stays alive.
    func collapse() {
        guard isExpanded else { return }
        collapseWork?.cancel(); collapseWork = nil
        isExpanded = false
        webView.removeFromSuperview()
        card.orderOut(nil)
        bubble.orderFrontRegardless()
    }

    /// Close the whole thing (menu toggle).
    func dismiss() {
        collapseWork?.cancel(); collapseWork = nil
        urlObservation = nil
        webView.removeFromSuperview()
        card.orderOut(nil)
        bubble.orderOut(nil)
    }

    private func positionCardNearBubble() {
        guard let screen = bubble.screen ?? NSScreen.main else { return }
        let b = bubble.frame
        var origin = NSPoint(x: b.minX, y: b.minY - Self.cardSize.height - 8)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8),
                       visible.maxX - Self.cardSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8),
                       visible.maxY - Self.cardSize.height - 8)
        card.setFrame(NSRect(origin: origin, size: card.frame.size), display: false)
    }

    // MARK: Auto-collapse on focus loss

    func windowDidResignKey(_ notification: Notification) {
        guard isExpanded else { return }
        // Short grace period so a transient focus change (a sheet, a panel)
        // doesn't yank the conversation away mid-sentence.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded, !self.card.isKeyWindow else { return }
            self.collapse()
        }
        collapseWork?.cancel()
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        collapseWork?.cancel(); collapseWork = nil
    }

    /// The card's close button collapses rather than destroying the bubble.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }

    // MARK: Unread badge (fed natively — no DOM work here)

    @objc private func unreadChanged(_ note: Notification) {
        bubbleView.unread = (note.userInfo?["count"] as? Int) ?? 0
    }

    // MARK: Position persistence

    private func saveOrigin() {
        let o = bubble.frame.origin
        UserDefaults.standard.set(["x": o.x, "y": o.y], forKey: Self.originKey)
    }
    private func restoreOrigin() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - Self.bubbleSize - 24,
                             y: visible.midY - Self.bubbleSize / 2)
        if let saved = UserDefaults.standard.dictionary(forKey: Self.originKey),
           let x = saved["x"] as? CGFloat, let y = saved["y"] as? CGFloat {
            origin = NSPoint(x: x, y: y)
        }
        // Clamp in case the display layout changed since we saved.
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.bubbleSize)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - Self.bubbleSize)
        bubble.setFrameOrigin(origin)
    }

    // MARK: Navigation — keep outbound links out of the bubble

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        if navigationAction.navigationType == .linkActivated, !Plume.isInternal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applySidebarVisibility()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Plume.isInternal(url) { webView.load(navigationAction.request) }
            else { NSWorkspace.shared.open(url) }
        }
        return nil
    }
}
