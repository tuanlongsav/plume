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
    /// When `followMessengerSite` last sent the feed on to the chat list.
    private var lastFeedRedirect: Date?
    /// The count the Dock badge shows now.
    private(set) var badgeCount = 0
    private var zeroRecheck: DispatchWorkItem?

    /// Single in-flight auto-retry, cancellable so a manual retry or a
    /// successful load can't leave a stale reload queued behind it.
    private var pendingRetry: DispatchWorkItem?

    /// WebKit does not retain a WKDownload across its async destination/finish
    /// callbacks, so we hold each one (and its chosen destination) ourselves
    /// for the download's lifetime.
    private var activeDownloads: Set<WKDownload> = []
    private var downloadDestinations: [WKDownload: URL] = [:]
    /// Delays the (undimmed) download progress pill so instant downloads — the
    /// common case — don't flash it.
    private var downloadLoadingWork: DispatchWorkItem?

    /// Which main-frame navigation is an attachment fetch: no loading pill
    /// for it, and its redirect off the CDN is not committed over the inbox.
    private var attachmentNav = AttachmentNavTracker()
    /// The sidebar row a native right-click menu is currently open for.
    private var pendingRowDelete: (url: URL, name: String)?

    /// Toolbar refreshes its button states through this after any nav change.
    var onChromeUpdate: (() -> Void)?
    /// Fired once, after the first load that actually succeeded.
    var onPageReady: (() -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()

        // Persist cookies / localStorage so login survives relaunches.
        config.websiteDataStore = .default()

        let controller = WKUserContentController()
        // Main frame only: every helper works on Messenger's own document, and
        // the bridge refuses messages from sub-frames anyway (ScriptBridge).
        let script = WKUserScript(
            source: InjectedScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        // One bridge handles every channel; the content controller retains it
        // while the bridge only weakly references us, so there is no cycle.
        let bridge = ScriptBridge(self)
        controller.add(bridge, name: "notify")
        controller.add(bridge, name: "notifyClose")
        controller.add(bridge, name: "rowMenu")
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
        webView.load(URLRequest(url: Plume.startURL))
    }

    // MARK: Tracker blocking

    private var trackerList: WKContentRuleList?

    /// Compile `TrackerRules` and attach it, then `done`. WebKit compiles off
    /// the main thread and keeps the result under the identifier; the first
    /// page load waits for it so the blocker covers that load too. `done` runs
    /// once even if the store fails, so the page always loads.
    func prepareTrackerBlocking(then done: @escaping () -> Void) {
        guard let store = WKContentRuleListStore.default() else { done(); return }
        store.compileContentRuleList(forIdentifier: TrackerRules.identifier,
                                     encodedContentRuleList: TrackerRules.json()) { [weak self] list, _ in
            DispatchQueue.main.async {
                self?.trackerList = list
                self?.applyTrackerBlocking()
                done()
            }
        }
    }

    /// On the shared content controller, so call windows opened from the
    /// page get it too. Takes effect from the next request.
    private func applyTrackerBlocking() {
        guard let list = trackerList else { return }
        let content = webView.configuration.userContentController
        content.remove(list)
        if Preferences.blockTrackers { content.add(list) }
    }

    var isBlockingTrackers: Bool { Preferences.blockTrackers }
    func toggleBlockTrackers() {
        Preferences.blockTrackers.toggle()
        applyTrackerBlocking()
    }

    /// View ▸ Back to Chats. On facebook.com a link in a chat (a profile, a
    /// post) is same-site and leaves the window on a page with no chat list.
    func goToChats() {
        let onFacebook = ThreadURL.site(of: webView.url) == .facebook
        webView.load(URLRequest(url: onFacebook ? Plume.facebookMessagesURL : Plume.startURL))
    }

    /// Facebook's login and security-check pages: nothing to read until the
    /// user has signed in.
    var isOnLoginPage: Bool {
        guard let url = webView.url, ThreadURL.site(of: url) == .facebook else { return false }
        return ["/login", "/checkpoint", "/two_step_verification"].contains { url.path.hasPrefix($0) }
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
        guard ThreadURL.site(of: webView.url) == .facebook else {
            // A title with no count (Messenger's "An sent you a message"
            // flash) keeps the last one; read as zero it blanked the badge
            // on every flash.
            if let count = UnreadTitle.count(from: title) { setBadge(count) }
            return
        }
        refreshFacebookBadge()
    }

    /// facebook.com's "(N)" also counts notifications and friend requests,
    /// which Plume cannot clear, and a "<name> messaged you" title flashes in
    /// and out of it. So there the title (or a message notification) is only
    /// the trigger: count unread chats in the list, on demand, no timer.
    private func refreshFacebookBadge(confirmingZero: Bool = false) {
        webView.evaluateJavaScript("window.__plumeUnreadCount ? window.__plumeUnreadCount() : -1") {
            [weak self] result, _ in
            guard let self, let n = (result as? NSNumber)?.intValue, n >= 0 else { return }
            if n == 0, self.badgeCount > 0, !confirmingZero {
                // A list in the middle of re-rendering reads as empty. Look
                // once more before clearing a badge the user has not seen go.
                self.zeroRecheck?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.refreshFacebookBadge(confirmingZero: true)
                }
                self.zeroRecheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
                return
            }
            self.zeroRecheck?.cancel()
            self.setBadge(n)
        }
    }

    /// Tell a newly built bubble chain the current count: it would otherwise
    /// wait for the next title change.
    func republishUnread() {
        setBadge(badgeCount)
    }

    // Messenger encodes the unread count as a *leading* "(N)" in the page
    // title, e.g. "(3) Messenger". Anchor on that: the title must start with
    // "(" and the parenthesised run must be all digits — so unrelated
    // parentheses ("Messenger (Work)") never register as unread.
    static func unreadCount(from title: String?) -> Int {
        UnreadTitle.count(from: title) ?? 0
    }

    /// Dock and app-chip badge text: nothing at zero, capped at "99+".
    static func badgeLabel(_ count: Int) -> String? {
        count > 99 ? "99+" : (count > 0 ? String(count) : nil)
    }

    // Called on the main thread (from title KVO); no dispatch needed.
    private func setBadge(_ count: Int) {
        badgeCount = count
        let label = Self.badgeLabel(count)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        // The chat bubble badges itself from this instead of watching the DOM.
        NotificationCenter.default.post(name: .plumeUnreadChanged, object: nil,
                                        userInfo: ["count": count])
    }

    // Reopen the thread tied to a clicked native notification.
    /// `completion` gets false when the page no longer knows that notification.
    func activateNotification(id: Int, completion: ((Bool) -> Void)? = nil) {
        webView.evaluateJavaScript("window.__plumeActivateNotification(\(id))") { result, _ in
            completion?((result as? Bool) == true)
        }
    }

    // MARK: Page zoom (main window only; see `lendWebView`)

    var pageZoom: Double { Preferences.pageZoom }

    func setPageZoom(_ zoom: Double) {
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
    func lendWebView() -> WKWebView? {
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
    func reclaimWebView() {
        guard let wv = webView, wv.superview !== view else { return }
        wv.pageZoom = CGFloat(Preferences.pageZoom)
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv, positioned: .below, relativeTo: view.subviews.first)
        NSLayoutConstraint.activate(pinEdges(wv, to: view))
    }

    // MARK: Conversation snapshot (chat bubbles)

    /// Read Messenger's conversation list once, on demand. Deliberately a
    /// snapshot and not an observer: the bubbles only need this when they are
    /// built or when the picker opens, and a live observer over this DOM is
    /// precisely the kind of thing that made the app crawl before.
    func fetchConversations(limit: Int,
                            completion: @escaping ([BubbleConversation]) -> Void) {
        webView.evaluateJavaScript("window.__plumeConvList(\(max(1, limit)))") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([BubbleConversation.Raw].self, from: data)
            else { completion([]); return }
            completion(raw.compactMap(BubbleConversation.init(raw:)))
        }
    }

    // MARK: Deleting a whole conversation

    var canDeleteCurrentConversation: Bool { ThreadURL.isThread(webView?.url) }

    /// Menu path: delete the conversation that is open right now.
    func deleteCurrentConversation() {
        guard let url = ThreadURL.canonical(from: webView.url) else { return }
        // The alert should name who is about to be deleted; the list knows.
        fetchConversations(limit: 80) { [weak self] convos in
            let id = ThreadURL.id(from: url)
            let name = convos.first { ThreadURL.id(from: $0.url) == id }?.name ?? ""
            self?.confirmAndDeleteConversation(url: url, name: name)
        }
    }

    /// Right-click on a row of Messenger's own sidebar (posted by the page).
    func handleRowMenu(_ body: [String: Any]) {
        guard let href = body["href"] as? String,
              let url = ThreadURL.canonical(from: URL(string: href)),
              let window = webView.window
        else { return }
        pendingRowDelete = (url, body["name"] as? String ?? "")
        let menu = NSMenu()
        menu.addItem(.deleteChat(target: self, action: #selector(deleteFromRowMenu)))
        menu.popUp(positioning: nil,
                   at: webView.convert(window.mouseLocationOutsideOfEventStream, from: nil),
                   in: webView)
    }

    @objc private func deleteFromRowMenu() {
        guard let (url, name) = pendingRowDelete else { return }
        pendingRowDelete = nil
        confirmAndDeleteConversation(url: url, name: name)
    }

    /// Ask first — Messenger cannot restore a deleted chat — then run
    /// Messenger's own delete flow. `completion` gets true only when the
    /// conversation is really gone.
    func confirmAndDeleteConversation(url: URL, name: String,
                                      completion: ((Bool) -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = name.isEmpty
            ? L.t("Xoá đoạn chat này?", "Delete this chat?")
            : L.t("Xoá đoạn chat với “\(name)”?", "Delete the chat with “\(name)”?")
        alert.informativeText = L.t(
            "Toàn bộ tin nhắn trong đoạn chat sẽ bị xoá vĩnh viễn khỏi tài khoản của bạn. Không thể hoàn tác.",
            "Every message in this chat will be permanently deleted from your account. This can't be undone.")
        // Cancel first, so Return never deletes.
        alert.addButton(withTitle: L.t("Huỷ", "Cancel"))
        alert.addButton(withTitle: L.t("Xoá", "Delete")).hasDestructiveAction = true

        let bubbles = ChatBubbleController.shared
        bubbles?.noteAttachmentPicker(active: true)   // a sheet must not fold the card
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            bubbles?.noteAttachmentPicker(active: false)
            guard response == .alertSecondButtonReturn, let self else { completion?(false); return }
            self.runDelete(url: url, completion: completion)
        }
        present(alert, completion: finish)
    }

    /// As a sheet on whichever window is showing Messenger. With no visible
    /// host (bubble card folded away) a sheet would never appear, so fall back
    /// to a modal raised above the `.screenSaver`-level bubbles.
    private func present(_ alert: NSAlert,
                         completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let host = ChatBubbleController.shared?.sheetHost ?? webView.window, host.isVisible {
            alert.beginSheetModal(for: host, completionHandler: completion)
        } else {
            alert.window.level = .screenSaver
            let response = alert.runModal()
            completion?(response)
        }
    }

    private func runDelete(url: URL, completion: ((Bool) -> Void)?) {
        webView.callAsyncJavaScript(InjectedScript.deleteThreadJS,
                                    arguments: ["href": url.absoluteString],
                                    in: nil, in: .page) { [weak self] result in
            let outcome = ThreadDeleteOutcome(result: try? result.get())
            if let message = outcome.failureMessage { self?.showDeleteFailure(message) }
            completion?(outcome == .ok)
        }
    }

    private func showDeleteFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("Chưa xoá được đoạn chat", "Couldn't delete the chat")
        alert.informativeText = message
        present(alert)
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

    /// Click Messenger's own "New message"; only when the page has none to
    /// click (list not loaded, or a Facebook page off the messages pages)
    /// load the compose page. The menu item is off in bubble mode, where a
    /// load would empty the list the chain is built from (AGENTS.md rule 4).
    func newMessage() {
        webView.evaluateJavaScript(
            "(function(){try{return !!(window.__plumeConv&&window.__plumeConv.newMessage())}catch(e){return false}})()"
        ) { [weak self] result, _ in
            guard let self, (result as? Bool) != true,
                  !ChatBubbleController.isOpen,
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

    // MARK: Tầng-B CSS theming

    /// Apply base + current toggle state. Called once each successful load.
    /// The master `webStyling` switch strips every layer when off.
    private func applyWebTheme() {
        guard Preferences.webStyling else {
            removeWebStyle(InjectedScript.StyleID.density)
            return
        }
        applyDensity()
    }
    private func applyDensity() {
        if Preferences.webStyling, Preferences.compact {
            setWebStyle(InjectedScript.StyleID.density, InjectedScript.densityCSS)
        } else {
            removeWebStyle(InjectedScript.StyleID.density)
        }
    }
    private func setWebStyle(_ id: String, _ css: String) {
        guard let idJSON = InjectedScript.stringLiteral(id),
              let cssJSON = InjectedScript.stringLiteral(css) else { return }
        webView.evaluateJavaScript("window.__plumeSetStyle(\(idJSON), \(cssJSON))", completionHandler: nil)
    }
    private func removeWebStyle(_ id: String) {
        guard let idJSON = InjectedScript.stringLiteral(id) else { return }
        webView.evaluateJavaScript("window.__plumeRemoveStyle(\(idJSON))", completionHandler: nil)
    }
}

// MARK: - Notifications / badge messages from JS

extension WebViewController {
    /// `fromPopup`: posted by a call window. Its page counts notification ids
    /// from 1 like ours does, so a click on it must not be routed to the main
    /// page's notification with the same number.
    func handleNotify(_ body: [String: Any], fromPopup: Bool = false) {
        guard let id = body["id"] as? Int else { return }
        let title = body["title"] as? String ?? "Messenger"
        let text = body["body"] as? String ?? ""

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        if !fromPopup { content.userInfo = ["plumeId": id] }

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(id: id, tag: body["tag"] as? String,
                                                    fromPopup: fromPopup),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        // A new message may not change the title (facebook.com), so it is a
        // trigger of its own for the badge and the bubble chain.
        updateBadgeFromTitle(webView.title)
    }

    func handleNotifyClose(_ body: [String: Any], fromPopup: Bool = false) {
        guard let id = body["id"] as? Int else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.notificationIdentifier(id: id, tag: body["tag"] as? String,
                                                          fromPopup: fromPopup)])
    }

    /// The web `tag` names a notification that a newer one with the same tag
    /// replaces (one entry per conversation, updated). Keyed by instance id
    /// alone, a burst of messages piled up as separate banners.
    static func notificationIdentifier(id: Int, tag: String?, fromPopup: Bool = false) -> String {
        let prefix = fromPopup ? "plume-popup-" : "plume-"
        if let tag, !tag.isEmpty { return prefix + "tag-" + tag }
        return prefix + "\(id)"
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
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
            Self.openExternally(url)
            decisionHandler(.cancel); return
        }
        if mainFrame { attachmentNav.decided(isAttachment: false) }
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
                Self.openExternally(url)
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
        // don't flash the loading pill for it. Any other navigation starting
        // supersedes whatever attachment fetch was in flight.
        if let navigation, attachmentNav.started(ObjectIdentifier(navigation)) { return }
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
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error, navigation: navigation)
    }

    // A failure after content started committing.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
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
    func webView(_ webView: WKWebView,
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
        if let url { Self.openExternally(url) }
        return nil
    }

    /// Shared with popup windows, which follow the same outbound rules.
    static func openExternally(_ url: URL) {
        guard Plume.isExternallyOpenable(url) else { return }
        NSWorkspace.shared.open(Plume.unwrapLinkShim(url))
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

        // Prefer a sheet on the bubble card (or the main window) so the picker
        // shares that window's Space / screen and stays above fullscreen apps.
        let host = ChatBubbleController.shared?.sheetHost ?? webView.window
        let bubbles = ChatBubbleController.shared
        bubbles?.noteAttachmentPicker(active: true)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            bubbles?.noteAttachmentPicker(active: false)
            completionHandler(response == .OK ? panel.urls : nil)
        }

        // A sheet on a window that is not on screen (the folded card) never
        // appears, so the page's file input would wait forever — same rule
        // as `present(_:)`.
        if let host, host.isVisible {
            // Inherit the card's overlay level so the sheet is not buried under
            // another app's fullscreen content on the same display.
            panel.level = host.level
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.begin(completionHandler: finish)
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
        decisionHandler(Plume.shouldAutoGrantCapture(originHost: origin.host,
                                                     frameHost: frame.securityOrigin.host)
                        ? .grant : .prompt)
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
    private func beginDownload(_ download: WKDownload) {
        download.delegate = self          // delegate is weak…
        activeDownloads.insert(download)  // …so keep a strong reference here
        scheduleDownloadIndicator()
    }

    /// Show the progress pill (no dim) only if a download is still running after
    /// a short delay — most attachments finish instantly.
    private func scheduleDownloadIndicator() {
        guard downloadLoadingWork == nil else { return }   // one timer covers all
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.activeDownloads.isEmpty else { return }
            self.setLoading(true, dimmed: false)
        }
        downloadLoadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Called when a download finishes/fails; clears the pill once none remain.
    private func downloadEnded() {
        guard activeDownloads.isEmpty else { return }
        downloadLoadingWork?.cancel()
        downloadLoadingWork = nil
        setLoading(false)
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
        downloadEnded()
        guard let url = dest else { return }
        if url.pathExtension.lowercased() == "pdf" {
            PDFViewerWindowController.open(url)                   // native in-app viewer
        } else {
            // Revealing the temp copy looked like a finished download, but
            // `clearDownloadCache` deletes it at the next launch. Keep the file
            // where a browser would; fall back to the temp copy if that fails.
            let kept = Self.moveToDownloads(url) ?? url
            NSWorkspace.shared.activateFileViewerSelecting([kept])
        }
    }

    /// Move a finished attachment into ~/Downloads under a free name
    /// ("name.ext", "name (2).ext", …). Returns nil if it can't.
    static func moveToDownloads(_ file: URL) -> URL? {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return nil }
        let ext = file.pathExtension
        let stem = file.deletingPathExtension().lastPathComponent
        for n in 1...999 {
            let name = n == 1 ? file.lastPathComponent
                : (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            let dest = downloads.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { continue }
            guard (try? fm.moveItem(at: file, to: dest)) != nil else { return nil }
            // The per-download temp folder is empty now.
            try? fm.removeItem(at: file.deletingLastPathComponent())
            return dest
        }
        return nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let filename = downloadDestinations[download]?.lastPathComponent
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        downloadEnded()   // clears the progress pill once no download remains
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
        // Message handlers are reachable from every frame, so an embedded
        // third-party frame could otherwise post spoofed native banners or
        // pop the delete menu. Only our page's own main frame may.
        let frame = message.frameInfo
        guard frame.isMainFrame, let controller,
              Plume.isInternal(host: frame.securityOrigin.host),
              let body = message.body as? [String: Any] else { return }
        // Call windows share this content controller, so their notifications
        // arrive here too; dropping them left the page told "granted" and the
        // user told nothing. Only the main page may open the delete menu.
        let fromPopup = message.webView !== controller.webView
        switch message.name {
        case "notify":      controller.handleNotify(body, fromPopup: fromPopup)
        case "notifyClose": controller.handleNotifyClose(body, fromPopup: fromPopup)
        case "rowMenu" where !fromPopup: controller.handleRowMenu(body)
        default: break
        }
    }
}

extension NSMenuItem {
    /// "Delete Chat…" with a trash icon: the row menus of Messenger's sidebar
    /// and of the bubble picker.
    static func deleteChat(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L.t("Xoá đoạn chat…", "Delete Chat…"),
                              action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return item
    }
}

extension Notification.Name {
    /// Posted by the main web view whenever the dock badge changes.
    static let plumeUnreadChanged = Notification.Name("plume.unreadChanged")
}
