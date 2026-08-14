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

    /// Single in-flight auto-retry, cancellable so a manual retry or a
    /// successful load can't leave a stale reload queued behind it.
    private var pendingRetry: DispatchWorkItem?

    /// WebKit does not retain a WKDownload across its async destination/finish
    /// callbacks, so we hold each one (and its chosen destination) ourselves
    /// for the download's lifetime.
    private var activeDownloads: Set<WKDownload> = []
    private var downloadDestinations: [WKDownload: URL] = [:]

    /// Set when the next main-frame navigation is an attachment we expect to
    /// turn into a download — so `didStartProvisionalNavigation` doesn't flash
    /// the "loading" pill for it. Consumed once, when that navigation starts.
    private var expectingAttachmentNav = false

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
        // drawsBackground is set by setContentState(.splash) below (false until
        // the first paint) — no separate anti-flash write needed here.
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

    /// Manual retry: drop any queued auto-retry so we don't fire twice.
    func retry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        load()
    }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    // Dark: force the native appearance (web content follows via
    // prefers-color-scheme). "Dark Mode" toggles forced-dark ⇄ forced-light off
    // its own override state (not the rendered appearance); "Follow System"
    // resets the override to nil.
    var isDarkForced: Bool { Preferences.forceDark == true }
    func toggleDark() {
        Preferences.forceDark = (Preferences.forceDark == true) ? false : true
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

    var isWebStyling: Bool { Preferences.webStyling }
    func toggleWebStyling() {
        Preferences.webStyling.toggle()
        applyWebTheme()
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

    // Messenger encodes the unread count as a *leading* "(N)" in the page
    // title, e.g. "(3) Messenger". Anchor on that: the title must start with
    // "(" and the parenthesised run must be all digits — so unrelated
    // parentheses ("Messenger (Work)") never register as unread.
    static func unreadCount(from title: String?) -> Int {
        guard let title, title.hasPrefix("("),
              let close = title.firstIndex(of: ")")
        else { return 0 }
        let inside = title[title.index(after: title.startIndex)..<close]
        guard !inside.isEmpty, inside.allSatisfy(\.isNumber) else { return 0 }
        return Int(inside) ?? 0
    }

    // Called on the main thread (from title KVO); no dispatch needed.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
    }

    // Reopen the thread tied to a clicked native notification.
    func activateNotification(id: Int) {
        webView.evaluateJavaScript("window.__plumeActivateNotification(\(id))", completionHandler: nil)
    }

    // MARK: Conversation navigation (Caprine port)

    private func runConvJS(_ call: String) {
        webView.evaluateJavaScript("try{window.__plumeConv&&window.__plumeConv.\(call)}catch(e){}",
                                   completionHandler: nil)
    }
    func jumpToConversation(_ n: Int)  { runConvJS("jumpTo(\(n))") }
    func nextConversation()            { runConvJS("next()") }
    func previousConversation()        { runConvJS("prev()") }
    func nextUnreadConversation()      { runConvJS("nextUnread()") }
    func findConversation()            { runConvJS("find()") }

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
    /// The master `webStyling` switch strips every layer when off.
    private func applyWebTheme() {
        guard Preferences.webStyling else {
            removeWebStyle(InjectedScript.StyleID.base)
            removeWebStyle(InjectedScript.StyleID.density)
            removeWebStyle(InjectedScript.StyleID.accent)
            removeWebStyle(InjectedScript.StyleID.code)
            return
        }
        setWebStyle(InjectedScript.StyleID.base, InjectedScript.baseCSS)
        setWebStyle(InjectedScript.StyleID.code, InjectedScript.codeCSS)
        applyDensity()
        applyAccent()
    }
    private func applyDensity() {
        if Preferences.webStyling, Preferences.compact {
            setWebStyle(InjectedScript.StyleID.density, InjectedScript.densityCSS)
        } else {
            removeWebStyle(InjectedScript.StyleID.density)
        }
    }
    private func applyAccent() {
        if Preferences.webStyling, Preferences.accent {
            setWebStyle(InjectedScript.StyleID.accent, InjectedScript.accentCSS)
        } else {
            removeWebStyle(InjectedScript.StyleID.accent)
        }
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
        // Web content explicitly asked to download (e.g. an <a download> link).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download); return
        }
        // A user clicking an outbound link → hand off to the real browser,
        // EXCEPT attachment-CDN links: allow those through so the response
        // handler can inspect the MIME / Content-Disposition and download them.
        if navigationAction.navigationType == .linkActivated, !Plume.isInternal(url) {
            if Plume.isAttachmentHost(url) {
                expectingAttachmentNav = true   // suppress the loading pill
                decisionHandler(.allow); return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url {
            let http = navigationResponse.response as? HTTPURLResponse
            // Compare the disposition *type* (the token before ';'), per RFC
            // 6266 — a filename like `inline; filename="q-attachment.pdf"` must
            // not be treated as an attachment.
            let dispositionType = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "")
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            // Download when the server forces it (any frame), or — for the main
            // frame only — WebKit can't render the type or it's an attachment-CDN
            // file. Sub-frame heuristics are gated so we don't grab an unrelated
            // navigation. Inline HTML and images/video from fbcdn.net render as
            // before.
            if dispositionType == "attachment"
                || (!navigationResponse.canShowMIMEType && navigationResponse.isForMainFrame)
                || (Plume.isAttachmentHost(url) && navigationResponse.isForMainFrame) {
                decisionHandler(.download); return
            }
        }
        decisionHandler(.allow)
    }

    // The two — and only two — points a navigation converts to a download.
    // `.download` aborts the navigation without committing a new document, so
    // Messenger stays put and no nav-failure delegate fires; we just need to
    // clear the loading overlay (a provisional nav may have started).
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        setLoading(false)
        beginDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        setLoading(false)
        beginDownload(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // An attachment navigation becomes a download almost immediately —
        // don't flash the loading pill for it.
        if expectingAttachmentNav { expectingAttachmentNav = false; return }
        // First paint is covered by the splash; later navigations (reload /
        // retry) get the non-blocking loading overlay.
        if hasLoadedOnce { setLoading(true) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingRetry?.cancel()
        pendingRetry = nil
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
        let ns = error as NSError
        setLoading(false)   // any nav ending clears the loading pill
        // Not real Messenger-connectivity failures — don't show offline:
        //  • a user-cancelled navigation (a link handed to the browser, or one
        //    attachment click superseding another);
        //  • a navigation we turned into a download (WebKit reports
        //    FrameLoadInterruptedByPolicyChange, 102);
        //  • an attachment fetch that failed before headers — it rides the main
        //    frame but must not slam the offline overlay over a healthy session.
        if ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        if let failing = Self.failingURL(from: ns), Plume.isAttachmentHost(failing) { return }
        setContentState(.offline)
        onChromeUpdate?()
        scheduleAutoRetry()
    }

    /// The URL WebKit was loading when a navigation failed, if the error
    /// carries it — used to tell an attachment-fetch failure apart from a real
    /// Messenger connectivity failure.
    private static func failingURL(from error: NSError) -> URL? {
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let s = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: s) }
        return nil
    }

    /// Queue a single retry ~3s out. If still offline it fails and reschedules,
    /// so the app self-heals when connectivity returns; the loading pill shows
    /// over the offline screen once the retry navigation starts. Replacing any
    /// prior work item keeps exactly one retry in flight.
    private func scheduleAutoRetry() {
        pendingRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.contentState == .offline else { return }
            self.load()
        }
        pendingRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
            if Plume.isAttachmentHost(url) {
                // Attachment-CDN URLs load in the main frame so the response
                // handler converts them to a download (without replacing the
                // current document); suppress the loading pill for them.
                expectingAttachmentNav = true
                webView.load(navigationAction.request)
            } else if Plume.isInternal(url) {
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
    // only for the call surfaces themselves (messenger.com / facebook.com).
    // Anything else — including CDN subdomains — gets the normal WebKit prompt
    // rather than a silent grant.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(Plume.isCallOrigin(host: origin.host) ? .grant : .prompt)
    }
}

// MARK: - Downloads (attachments → in-app PDF viewer or Finder reveal)

extension WebViewController: WKDownloadDelegate {
    /// Throwaway view-copies of opened attachments live here.
    static let downloadsDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlumeAttachments", isDirectory: true)

    /// Delete stale attachment copies — call once at launch. They're view-only
    /// (the user's durable copy is whatever they Save-a-Copy'd), no PDF window
    /// survives a relaunch, so nothing here is still needed.
    static func clearDownloadCache() {
        try? FileManager.default.removeItem(at: downloadsDir)
    }

    /// Hold the download and start delegating its callbacks to us.
    func beginDownload(_ download: WKDownload) {
        download.delegate = self          // delegate is weak…
        activeDownloads.insert(download)  // …so keep a strong reference here
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        // Per-download UUID subdir: duplicate filenames never collide and the
        // returned URL is guaranteed not to pre-exist (WebKit requires that).
        let dir = Self.downloadsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Defence in depth: the sender influences the filename, so strip any
        // path components (WebKit sanitises too, but never trust it) — a
        // "../../x" name must not escape the per-download temp dir.
        let leaf = (suggestedFilename as NSString).lastPathComponent
        let name = leaf.isEmpty ? "attachment" : leaf
        let dest = dir.appendingPathComponent(name)
        downloadDestinations[download] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let dest = downloadDestinations[download]
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        guard let url = dest else { return }
        if url.pathExtension.lowercased() == "pdf" {
            PDFViewerWindowController.open(url)                   // native in-app viewer
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url]) // reveal other files
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let filename = downloadDestinations[download]?.lastPathComponent
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        setLoading(false)   // the main frame was never navigated; no offline overlay
        // A superseded download (another attachment click) cancels this one —
        // not worth surfacing. Everything else failed a user-requested open.
        if (error as NSError).code == NSURLErrorCancelled { return }
        notifyDownloadFailed(filename)
    }

    private func notifyDownloadFailed(_ filename: String?) {
        let content = UNMutableNotificationContent()
        content.title = L.t("Không tải được tệp", "Download failed")
        content.body = filename.map { L.t("Không tải được “\($0)”.", "Couldn't download “\($0)”.") }
            ?? L.t("Không tải được tệp đính kèm.", "Couldn't download the attachment.")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "plume-dlfail-\(UUID().uuidString)",
                                  content: content, trigger: nil),
            withCompletionHandler: nil)
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
