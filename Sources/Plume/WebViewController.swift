import AppKit
import WebKit
import UserNotifications

/// Owns the WKWebView that renders Messenger and wires up the native
/// integrations: notifications, badge, external-link handling, file
/// uploads and camera/mic for calls.
final class WebViewController: NSViewController {
    private(set) var webView: WKWebView!

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
        controller.add(ScriptBridge(self), name: "notify")
        controller.add(ScriptBridge(self), name: "notifyClose")
        controller.add(ScriptBridge(self), name: "badge")
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

        // KVO the title to keep the dock badge in sync as a fallback.
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)

        self.webView = wv
        self.view = wv
    }

    func load() {
        webView.load(URLRequest(url: Plume.homeURL))
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.title) {
            updateBadgeFromTitle(webView.title)
        }
    }

    private func updateBadgeFromTitle(_ title: String?) {
        guard let title, let range = title.range(of: #"\((\d+)\)"#, options: .regularExpression) else {
            setBadge(0); return
        }
        let digits = title[range].filter(\.isNumber)
        setBadge(Int(digits) ?? 0)
    }

    func setBadge(_ count: Int) {
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
    }

    // Reopen the thread tied to a clicked native notification.
    func activateNotification(id: Int) {
        webView.evaluateJavaScript("window.__plumeActivateNotification(\(id))", completionHandler: nil)
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

    func handleBadge(_ body: [String: Any]) {
        if let count = body["count"] as? Int { setBadge(count) }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Once content is up, draw the background again to match the page.
        webView.setValue(true, forKey: "drawsBackground")
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
    // (macOS still gates the real hardware behind its own TCC prompt).
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
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
        case "badge":       controller?.handleBadge(body)
        default: break
        }
    }
}
