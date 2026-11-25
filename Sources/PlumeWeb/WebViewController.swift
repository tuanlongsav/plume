import AppKit
import PlumeCore
import PlumeUI
import WebKit

/// Owns the `WKWebView` that renders Messenger, its app-state overlays
/// (splash / loading / offline), navigation/UI delegates, and lending to the
/// bubble card. Domain concerns (JS bridge, notifications/badge, downloads,
/// thread deletion, styling/tracker blocking) are delegated to focused
/// coordinators.
public final class WebViewController: NSViewController {
    public private(set) var webView: WKWebView!
    public private(set) var pageBridge: MessengerPageBridge!

    private let notifications = WebNotificationBridge()
    private let downloads = AttachmentDownloadManager()
    private let threadDeletion = ThreadDeletionCoordinator()
    private let styling = WebStylingCoordinator()

    // App-state overlays
    private var splashView: SplashView!
    private var loadingView: LoadingView!
    private var offlineView: OfflineView!

    /// Mutually-exclusive opaque backdrop.
    private enum ContentState { case splash, main, offline }
    private var contentState: ContentState = .splash
    private var hasLoadedOnce = false
    /// When `followMessengerSite` last sent the feed on to the chat list.
    private var lastFeedRedirect: Date?

    /// Single in-flight auto-retry, cancellable so a manual retry or a
    /// successful load can't leave a stale reload queued behind it.
    private var pendingRetry: DispatchWorkItem?

    /// Which main-frame navigation is an attachment fetch: no loading pill
    /// for it, and its redirect off the CDN is not committed over the inbox.
    private var attachmentNav = AttachmentNavTracker()

    /// Toolbar refreshes its button states through this after any nav change.
    public var onChromeUpdate: (() -> Void)? {
        didSet { styling.onChromeUpdate = onChromeUpdate }
    }
    /// Fired once, after the first load that actually succeeded.
    public var onPageReady: (() -> Void)?

    public var badgeCount: Int { notifications.badgeCount }

    public static func applyAppearance() { WebStylingCoordinator.applyAppearance() }
    public static func clearDownloadCache() { AttachmentDownloadManager.clearDownloadCache() }

    public override func loadView() {
        let config = WKWebViewConfiguration()

        // Persist cookies / localStorage so login survives relaunches.
        config.websiteDataStore = .default()

        let controller = WKUserContentController()
        // Main frame only: every helper works on Messenger's own document, and
        // the bridge refuses messages from sub-frames anyway (WebNotificationBridge).
        let script = WKUserScript(
            source: InjectedScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        notifications.install(on: controller)
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
        wv.pageZoom = CGFloat(Preferences.pageZoom)
        #if DEBUG
        // Safari ▸ Develop can attach to the page, so injected JS is debugged
        // in a real inspector instead of through PlumeTrace lines.
        wv.isInspectable = true
        #endif
        wv.navigationDelegate = self
        wv.uiDelegate = self
        // drawsBackground is set by setContentState(.splash) below (false until
        // the first paint) — no separate anti-flash write needed here.
        wv.translatesAutoresizingMaskIntoConstraints = false

        // KVO the title to keep the dock badge in sync as a fallback.
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)
        self.webView = wv

        let bridge = MessengerPageBridge(webView: wv)
        self.pageBridge = bridge
        notifications.attach(webView: wv, pageBridge: bridge)
        notifications.onRowMenu = { [weak self] body in self?.threadDeletion.handleRowMenu(body) }
        threadDeletion.attach(webView: wv, pageBridge: bridge)
        styling.attach(webView: wv, pageBridge: bridge)
        styling.onChromeUpdate = onChromeUpdate
        downloads.onLoadingChanged = { [weak self] loading in
            self?.setLoading(loading, dimmed: false)
        }

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

        NSLayoutConstraint.activate(
            wv.pinEdges(to: container) + overlays.flatMap { $0.pinEdges(to: container) }
        )

        self.view = container
        setContentState(.splash)   // no blank flash before the first paint
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                      change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.title) {
            notifications.updateBadgeFromTitle(webView.title)
        }
    }

    // MARK: Loading & Navigation

    public func load() {
        webView.load(URLRequest(url: Plume.startURL))
    }

    public func prepareTrackerBlocking(then done: @escaping () -> Void) {
        styling.prepareTrackerBlocking(then: done)
    }

    public var isBlockingTrackers: Bool { styling.isBlockingTrackers }
    public func toggleBlockTrackers() { styling.toggleBlockTrackers() }

    /// View ▸ Back to Chats. On facebook.com a link in a chat (a profile, a
    /// post) is same-site and leaves the window on a page with no chat list.
    public func goToChats() {
        let onFacebook = ThreadURL.site(of: webView.url) == .facebook
        webView.load(URLRequest(url: onFacebook ? Plume.facebookMessagesURL : Plume.startURL))
    }

    /// Facebook's login and security-check pages: nothing to read until the
    /// user has signed in.
    public var isOnLoginPage: Bool {
        guard let url = webView.url, ThreadURL.site(of: url) == .facebook else { return false }
        return ["/login", "/checkpoint", "/two_step_verification"].contains { url.path.hasPrefix($0) }
    }

    // MARK: Chrome actions

    public func reload() { webView.reload() }
    public func goBack() { if webView.canGoBack { webView.goBack() } }
    public func goForward() { if webView.canGoForward { webView.goForward() } }

    /// Manual retry: drop any queued auto-retry so we don't fire twice.
    public func retry() {
        pendingRetry?.cancel()
        pendingRetry = nil
        load()
    }

    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }

    public var isDarkForced: Bool { styling.isDarkForced }
    public func toggleDark() { styling.toggleDark() }
    public func followSystemAppearance() { styling.followSystemAppearance() }

    public var isCompact: Bool { styling.isCompact }
    public func toggleCompact() { styling.toggleCompact() }

    public var isWebStyling: Bool { styling.isWebStyling }
    public func toggleWebStyling() { styling.toggleWebStyling() }

    // MARK: Notifications & Badge

    public func republishUnread() {
        notifications.republishUnread()
    }

    public func activateNotification(id: Int, completion: ((Bool) -> Void)? = nil) {
        pageBridge.activateNotification(id: id, completion: completion)
    }

    // MARK: Page zoom (main window only; see `lendWebView`)

    public var pageZoom: Double { Preferences.pageZoom }

    public func setPageZoom(_ zoom: Double) {
        let zoom = PageZoom.clamped(zoom)
        Preferences.pageZoom = zoom
        // Lent to the bubble card, the web view stays at 1; the new level
        // applies when the main window takes it back.
        if webView.superview === view { webView.pageZoom = CGFloat(zoom) }
    }

    // MARK: Lending the web view to the chat bubble card

    /// Hand the live web view to the bubble card.
    ///
    /// The card used to run a second WKWebView, which meant loading the whole
    /// Messenger app again — seconds of waiting on the first bubble opened, and
    /// two copies rendering from then on. There is only ever one conversation
    /// on screen, so there only needs to be one web view; it simply moves.
    public func lendWebView() -> WKWebView? {
        guard let wv = webView, wv.superview === view else { return webView }
        wv.removeFromSuperview()
        // The card is sized to just clear Messenger's ~900 CSS-px breakpoint
        // (`messengerFloor`); any zoom above 1 would shrink the viewport
        // below it and drop the conversation from the card. The window's
        // zoom comes back with `reclaimWebView`.
        wv.pageZoom = 1
        return wv
    }

    /// Take it back. Idempotent, and safe to call even if it was never lent —
    /// a main window with no web view in it is the one failure worth ruling out.
    public func reclaimWebView() {
        guard let wv = webView, wv.superview !== view else { return }
        wv.pageZoom = CGFloat(Preferences.pageZoom)
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv, positioned: .below, relativeTo: view.subviews.first)
        NSLayoutConstraint.activate(wv.pinEdges(to: view))
    }

    // MARK: Conversation snapshot, navigation & deletion

    public func fetchConversations(limit: Int,
                                   completion: @escaping ([BubbleConversation]) -> Void) {
        pageBridge.fetchConversations(limit: limit, completion: completion)
    }

    public var canDeleteCurrentConversation: Bool {
        threadDeletion.canDeleteCurrentConversation
    }

    public func deleteCurrentConversation() {
        threadDeletion.deleteCurrentConversation()
    }

    public func confirmAndDeleteConversation(url: URL, name: String,
                                             completion: ((Bool) -> Void)? = nil) {
        threadDeletion.confirmAndDeleteConversation(url: url, name: name, completion: completion)
    }

    public func jumpToConversation(_ n: Int) { pageBridge.runConversationAction("jumpTo(\(n))") }
    public func nextConversation()           { pageBridge.runConversationAction("next()") }
    public func previousConversation()       { pageBridge.runConversationAction("prev()") }
    public func nextUnreadConversation()     { pageBridge.runConversationAction("nextUnread()") }
    public func findConversation()           { pageBridge.runConversationAction("find()") }

    /// Click Messenger's own "New message"; only when the page has none to
    /// click (list not loaded, or a Facebook page off the messages pages)
    /// load the compose page. The menu item is off in bubble mode, where a
    /// load would empty the list the chain is built from (AGENTS.md rule 4).
    public func newMessage() {
        pageBridge.triggerNewMessage { [weak self] handled in
            guard let self, !handled,
                  !PlumeOverlay.isActive,
                  let url = ThreadURL.newMessageURL(from: self.webView.url)
            else { return }
            self.webView.load(URLRequest(url: url))
        }
    }

    // MARK: App-state overlays

    private func setContentState(_ state: ContentState) {
        contentState = state
        splashView.isHidden = state != .splash
        offlineView.isHidden = state != .offline
        if state == .splash { splashView.startAnimating() } else { splashView.stopAnimating() }
        if Self.canSetDrawsBackground {
            webView.setValue(state == .main, forKey: "drawsBackground")
        }
    }

    /// `drawsBackground` is WebKit SPI with no public setter. KVC on a key
    /// that has gone away raises NSUnknownKeyException, which here would crash
    /// at launch; without it the opaque splash/offline overlays still cover
    /// the first paint.
    private static let canSetDrawsBackground =
        WKWebView.instancesRespond(to: Selector(("_setDrawsBackground:")))
        || WKWebView.instancesRespond(to: Selector(("setDrawsBackground:")))

    private func setLoading(_ on: Bool, dimmed: Bool = true) {
        loadingView.isHidden = !on
        if on { loadingView.startAnimating(dimmed: dimmed) } else { loadingView.stopAnimating() }
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Every allowed main-frame decision is recorded, so the attachment
        // expectation always belongs to the navigation that starts next.
        let mainFrame = navigationAction.targetFrame?.isMainFrame == true
        guard let url = navigationAction.request.url else {
            if mainFrame { attachmentNav.decided(isAttachment: false) }
            decisionHandler(.allow); return
        }
        // Web content explicitly asked to download (e.g. an <a download> link).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download); return
        }
        // A user clicking an outbound link → hand off to the real browser,
        // EXCEPT attachment-CDN links: allow those through so the response
        // handler can inspect the MIME / Content-Disposition and download them.
        // Non-web schemes are cancelled, not loaded over the Messenger page.
        if navigationAction.navigationType == .linkActivated, !Plume.isInternal(url) {
            if Plume.isAttachmentHost(url) {
                if mainFrame { attachmentNav.decided(isAttachment: true) }
                decisionHandler(.allow); return
            }
            ExternalLinkOpener.open(url)
            decisionHandler(.cancel); return
        }
        if mainFrame { attachmentNav.decided(isAttachment: false) }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView,
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
            // A main-frame response belongs to the latest main-frame
            // navigation, the only one the tracker can have tagged.
            let pendingAttachment = navigationResponse.isForMainFrame
                && attachmentNav.responseForMainFrame()
            if dispositionType == "attachment"
                || (!navigationResponse.canShowMIMEType && navigationResponse.isForMainFrame)
                || (Plume.isAttachmentHost(url) && navigationResponse.isForMainFrame) {
                decisionHandler(.download); return
            }
            // An attachment link that redirected somewhere renderable (an
            // expired link's error page, a login checkpoint) would otherwise
            // commit over the live inbox — and the next bubble snapshot of an
            // empty inbox deletes every bubble (AGENTS.md rule 4).
            if pendingAttachment {
                ExternalLinkOpener.open(url)
                decisionHandler(.cancel); return
            }
        }
        if navigationResponse.isForMainFrame { _ = attachmentNav.responseForMainFrame() }
        decisionHandler(.allow)
    }

    // The two — and only two — points a navigation converts to a download.
    // `.download` aborts the navigation without committing a new document, so
    // Messenger stays put and no nav-failure delegate fires; we just need to
    // clear the loading overlay (a provisional nav may have started).
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        setLoading(false)
        downloads.beginDownload(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        setLoading(false)
        downloads.beginDownload(download)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // An attachment navigation becomes a download almost immediately —
        // don't flash the loading pill for it. Any other navigation starting
        // supersedes whatever attachment fetch was in flight.
        if let navigation, attachmentNav.started(ObjectIdentifier(navigation)) { return }
        // First paint is covered by the splash; later navigations (reload /
        // retry) get the non-blocking loading overlay.
        if hasLoadedOnce { setLoading(true) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingRetry?.cancel()
        pendingRetry = nil
        hasLoadedOnce = true
        setContentState(.main)
        setLoading(false)
        styling.applyWebTheme()
        followMessengerSite()
        onChromeUpdate?()
        // Deliberately separate from onChromeUpdate: that also fires on a load
        // FAILURE (handleLoadFailure calls it), and anything hooked there for
        // "the page is ready" would burn its one shot while offline.
        let ready = onPageReady
        onPageReady = nil
        ready?()
    }

    /// Remember which site the account lives on, and take a login that lands
    /// on the Facebook feed on to the chat list. Full loads only: Facebook's
    /// own Home link routes in-page, never reaches didFinish, and is respected.
    private func followMessengerSite() {
        guard let url = webView.url, let site = ThreadURL.site(of: url) else { return }
        if ThreadURL.isMessagesSurface(url) {
            if Preferences.messengerSite != site { Preferences.messengerSite = site }
            return
        }
        guard site == .facebook, ["", "/", "/home.php"].contains(url.path) else { return }
        // Should /messages/ ever send us back here, this is not a loop.
        if let last = lastFeedRedirect, Date().timeIntervalSince(last) < 30 { return }
        lastFeedRedirect = Date()
        webView.load(URLRequest(url: Plume.facebookMessagesURL))
    }

    // A failed *provisional* load (DNS/offline/TLS before any content).
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        handleLoadFailure(error, navigation: navigation)
    }

    // A failure after content started committing.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: Error) {
        handleLoadFailure(error, navigation: navigation)
    }

    private func handleLoadFailure(_ error: Error, navigation: WKNavigation?) {
        let ns = error as NSError
        // Only the failing navigation's own state ends with it: a superseded
        // attachment fetch fails AFTER its successor was already tagged.
        if let navigation { attachmentNav.failed(ObjectIdentifier(navigation)) }
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
    // target=_blank / window.open: attachments download, our own pages (and
    // the blank page a call window starts on) get a real window, the rest of
    // the web goes to the browser. Never into this web view: that replaced
    // the live inbox, and `window.open` returning null broke calls.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        if let url, Plume.isAttachmentHost(url) {
            // Attachment-CDN URLs load in the main frame so the response
            // handler converts them to a download (without replacing the
            // current document); suppress the loading pill for them.
            if let navigation = webView.load(navigationAction.request) {
                attachmentNav.loadedDirectly(ObjectIdentifier(navigation))
            }
            return nil
        }
        if Plume.opensInPopup(url) {
            return PopupWindowController.open(configuration: configuration, features: windowFeatures)
        }
        if let url { ExternalLinkOpener.open(url) }
        return nil
    }

    // Native file picker for attachments.
    public func webView(_ webView: WKWebView,
                        runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true

        // Prefer a sheet on the bubble card (or the main window) so the picker
        // shares that window's Space / screen and stays above fullscreen apps.
        let overlayHost = PlumeOverlay.activeHost
        let host = overlayHost?.sheetHost ?? webView.window
        overlayHost?.setModalPresentationActive(true)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            overlayHost?.setModalPresentationActive(false)
            completionHandler(response == .OK ? panel.urls : nil)
        }

        // A sheet on a window that is not on screen (the folded card) never
        // appears, so the page's file input would wait forever.
        if let host, host.isVisible {
            // Inherit the card's overlay level so the sheet is not buried under
            // another app's fullscreen content on the same display.
            panel.level = host.level
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            panel.level = PlumeOverlay.level
            panel.collectionBehavior = PlumeOverlay.collectionBehavior
            panel.begin(completionHandler: finish)
        }
    }

    // Grant camera/mic so voice & video calls work without a second prompt
    // (macOS still gates the real hardware behind its own TCC prompt) — but
    // only for the call surfaces themselves (messenger.com / facebook.com).
    // Anything else — including CDN subdomains — gets the normal WebKit prompt
    // rather than a silent grant.
    public func webView(_ webView: WKWebView,
                        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(Plume.shouldAutoGrantCapture(originHost: origin.host,
                                                     frameHost: frame.securityOrigin.host)
                        ? .grant : .prompt)
    }
}
