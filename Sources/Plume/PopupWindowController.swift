import AppKit
import WebKit

/// A real window for pages Messenger opens with `window.open` — above all the
/// call window, which it opens on `about:blank` and then navigates to the
/// call URL. Returning nil from `createWebViewWith` made `window.open` return
/// null, so calls never started; loading the URL into the main web view
/// instead replaced the live inbox.
///
/// Like `PDFViewerWindowController`, the controller keeps itself alive through
/// `registry` and releases on `windowWillClose`.
final class PopupWindowController: NSWindowController {

    private static var registry: [PopupWindowController] = []

    /// WebKit requires the returned view to be built from exactly the
    /// configuration it passes in, which also shares the opener's session.
    static func open(configuration: WKWebViewConfiguration,
                     features: WKWindowFeatures) -> WKWebView {
        let controller = PopupWindowController(configuration: configuration, features: features)
        registry.append(controller)
        controller.showWindow(nil)
        return controller.webView
    }

    let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    private static let minSize = NSSize(width: 360, height: 280)

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.customUserAgent = Plume.userAgent
        webView = wv

        let size = NSSize(
            width: features.width.map { max(PopupWindowController.minSize.width, CGFloat(truncating: $0)) } ?? 960,
            height: features.height.map { max(PopupWindowController.minSize.height, CGFloat(truncating: $0)) } ?? 640)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Plume"
        window.minSize = PopupWindowController.minSize
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false       // ARC + our registry own it
        window.contentView = wv

        super.init(window: window)

        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // The bubble card floats at screen-saver level; a call started from it
        // would otherwise open underneath. Same treatment as the file picker.
        if ChatBubbleController.isOpen {
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.center()

        titleObservation = webView.observe(\.title) { [weak self] wv, _ in
            guard let title = wv.title, !title.isEmpty else { return }
            self?.window?.title = title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - NSWindowDelegate (lifetime release)

extension PopupWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        // Closing the window must end the call now, not whenever ARC gets to
        // the view: blanking the page tears down its camera/mic streams.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        Self.registry.removeAll { $0 === self }
    }
}

// MARK: - Web view delegates

extension PopupWindowController: WKUIDelegate, WKNavigationDelegate {
    /// The page calls `window.close()` when the call ends.
    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        if Plume.opensInPopup(url) {
            return Self.open(configuration: configuration, features: windowFeatures)
        }
        if let url { WebViewController.openExternally(url) }
        return nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, !Plume.isInternal(url) {
            WebViewController.openExternally(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    // Same rule as the main window: only the call surfaces get camera/mic
    // without WebKit's prompt.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(Plume.isCallOrigin(host: origin.host) ? .grant : .prompt)
    }
}
