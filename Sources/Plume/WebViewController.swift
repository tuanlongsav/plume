import AppKit
import WebKit
import UserNotifications

/// Owns the WKWebView that renders Messenger and wires up the native
/// integrations: notifications, badge, external-link handling, file
/// uploads and camera/mic for calls. Also drives the redesign's app-state
/// overlays (splash / loading / offline) and the tầng-B CSS theming.
final class WebViewController: NSViewController {
    private(set) var webView: WKWebView!

    // App-state overlays
    private var splashView: SplashView!
    private var loadingView: LoadingView!
    private var offlineView: OfflineView!

    /// Mutually-exclusive opaque backdrop.
    private enum ContentState { case splash, main, offline }
    private var contentState: ContentState = .splash
    private var hasLoadedOnce = false

    /// Toolbar refreshes its button states through this after any nav change.
    var onChromeUpdate: (() -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()

        // Persist cookies / localStorage so login survives relaunches.
        config.websiteDataStore = .default()

        let controller = WKUserContentController()
        let script = WKUserScript(
            source: InjectedScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(script)
        // One bridge handles every channel; the content controller retains it
        // while the bridge only weakly references us, so there is no cycle.
        let bridge = ScriptBridge(self)
        controller.add(bridge, name: "notify")
        controller.add(bridge, name: "notifyClose")
        config.userContentController = controller

        // Let HTML5 audio/video (call ringtones, voice clips) autoplay.
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Plume.userAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground") // avoid white flash on load
        wv.translatesAutoresizingMaskIntoConstraints = false

        // KVO the title to keep the dock badge in sync as a fallback.
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)
        self.webView = wv

        // Container: web view + state overlays stacked on top.
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(wv)

        offlineView = OfflineView()
        offlineView.onRetry = { [weak self] in self?.retry() }
        splashView = SplashView()
        loadingView = LoadingView()
        let overlays: [NSView] = [offlineView, splashView, loadingView]
        for overlay in overlays {
            container.addSubview(overlay)
            overlay.isHidden = true
        }

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ] + overlays.flatMap { pinEdges($0, to: container) })

        self.view = container
        setContentState(.splash)   // no blank flash before the first paint
    }

    private func pinEdges(_ v: NSView, to c: NSView) -> [NSLayoutConstraint] {
        [v.topAnchor.constraint(equalTo: c.topAnchor),
         v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
         v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
         v.bottomAnchor.constraint(equalTo: c.bottomAnchor)]
    }

    func load() {
        webView.load(URLRequest(url: Plume.homeURL))
    }

    // MARK: Chrome actions

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func retry() { load() }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    // Dark: force the native appearance (web content follows via
    // prefers-color-scheme). Toggling flips between forcing dark and light.
    var isDark: Bool { NSApp.effectiveAppearance.isDark }
    func toggleDark() {
        Preferences.forceDark = isDark ? false : true
        WebViewController.applyAppearance()
        onChromeUpdate?()
    }
    static func applyAppearance() {
        switch Preferences.forceDark {
        case .some(true):  NSApp.appearance = NSAppearance(named: .darkAqua)
        case .some(false): NSApp.appearance = NSAppearance(named: .aqua)
        case .none:        NSApp.appearance = nil
        }
    }
    func followSystemAppearance() {
        Preferences.forceDark = nil
        WebViewController.applyAppearance()
        onChromeUpdate?()
    }

    var isCompact: Bool { Preferences.compact }
    func toggleCompact() {
        Preferences.compact.toggle()
        applyDensity()
        onChromeUpdate?()
    }

    var isAccentOn: Bool { Preferences.accent }
    func toggleAccent() {
        Preferences.accent.toggle()
        applyAccent()
        onChromeUpdate?()
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.title) {
            updateBadgeFromTitle(webView.title)
        }
    }

    // MARK: Badge

    private func updateBadgeFromTitle(_ title: String?) {
        setBadge(Self.unreadCount(from: title))
    }

    // Messenger encodes the unread count as a leading "(N)" in the page title,
    // e.g. "(3) Messenger". Scan for it directly instead of compiling a regex
    // on every title change.
    static func unreadCount(from title: String?) -> Int {
        guard let title,
              let open = title.firstIndex(of: "("),
              let close = title[title.index(after: open)...].firstIndex(of: ")")
        else { return 0 }
        let digits = title[title.index(after: open)..<close].filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // Called on the main thread (from title KVO); no dispatch needed.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
    }

    // Reopen the thread tied to a clicked native notification.
    func activateNotification(id: Int) {
        webView.evaluateJavaScript("window.__plumeActivateNotification(\(id))", completionHandler: nil)
    }

    // MARK: App-state overlays

    private func setContentState(_ state: ContentState) {
        contentState = state
        splashView.isHidden = state != .splash
        offlineView.isHidden = state != .offline
        if state == .splash { splashView.startAnimating() } else { splashView.stopAnimating() }
        webView.setValue(state == .main, forKey: "drawsBackground")
    }

    private func setLoading(_ on: Bool) {
        loadingView.isHidden = !on
        if on { loadingView.startAnimating() } else { loadingView.stopAnimating() }
    }

    // MARK: Tầng-B CSS theming

    /// Apply base + current toggle state. Called once each successful load.
    private func applyWebTheme() {
        setWebStyle(InjectedScript.StyleID.base, InjectedScript.baseCSS)
        applyDensity()
        applyAccent()
    }
    private func applyDensity() {
        if Preferences.compact { setWebStyle(InjectedScript.StyleID.density, InjectedScript.densityCSS) }
        else { removeWebStyle(InjectedScript.StyleID.density) }
    }
    private func applyAccent() {
        if Preferences.accent { setWebStyle(InjectedScript.StyleID.accent, InjectedScript.accentCSS) }
        else { removeWebStyle(InjectedScript.StyleID.accent) }
    }
    private func setWebStyle(_ id: String, _ css: String) {
        guard let idJSON = jsonString(id), let cssJSON = jsonString(css) else { return }
        webView.evaluateJavaScript("window.__plumeSetStyle(\(idJSON), \(cssJSON))", completionHandler: nil)
    }
    private func removeWebStyle(_ id: String) {
        guard let idJSON = jsonString(id) else { return }
        webView.evaluateJavaScript("window.__plumeRemoveStyle(\(idJSON))", completionHandler: nil)
    }
    private func jsonString(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Notifications / badge messages from JS

extension WebViewController {
    func handleNotify(_ body: [String: Any]) {
        guard let id = body["id"] as? Int else { return }
        let title = body["title"] as? String ?? "Messenger"
        let text = body["body"] as? String ?? ""

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        content.userInfo = ["plumeId": id]

        let request = UNNotificationRequest(
            identifier: "plume-\(id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func handleNotifyClose(_ body: [String: Any]) {
        guard let id = body["id"] as? Int else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["plume-\(id)"])
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // A user clicking an outbound link → hand off to the real browser.
        if navigationAction.navigationType == .linkActivated, !Plume.isInternal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // First paint is covered by the splash; later navigations (reload /
        // retry) get the non-blocking loading overlay.
        if hasLoadedOnce { setLoading(true) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedOnce = true
        setContentState(.main)
        setLoading(false)
        applyWebTheme()
        onChromeUpdate?()
    }

    // A failed *provisional* load (DNS/offline/TLS before any content).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error)
    }

    // A failure after content started committing.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        // The user cancelling a navigation (e.g. clicking a link we hand off
        // to the browser) is not a failure worth reacting to.
        if (error as NSError).code == NSURLErrorCancelled { return }
        setLoading(false)
        setContentState(.offline)
        onChromeUpdate?()
        // Auto-retry: if still offline the retry fails and reschedules, so the
        // app self-heals when connectivity returns. The loading pill appears
        // over the offline screen once the retry navigation starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.contentState == .offline else { return }
            self.load()
        }
    }
}

// MARK: - UI delegate (popups, file pickers, media permission)

extension WebViewController: WKUIDelegate {
    // target=_blank / window.open → open externally instead of a popup.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Plume.isInternal(url) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    // Native file picker for attachments.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // Grant camera/mic so voice & video calls work without a second prompt
    // (macOS still gates the real hardware behind its own TCC prompt) — but
    // only for Messenger/Facebook itself. A third-party frame gets the normal
    // WebKit prompt instead of a silent grant.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(Plume.isInternal(host: origin.host) ? .grant : .prompt)
    }
}

/// Thin trampoline so each message-handler name forwards to the controller
/// without retaining it in a cycle through WKUserContentController.
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var controller: WebViewController?
    init(_ controller: WebViewController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "notify":      controller?.handleNotify(body)
        case "notifyClose": controller?.handleNotifyClose(body)
        default: break
        }
    }
}
