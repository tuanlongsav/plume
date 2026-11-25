import Foundation
import PlumeCore
import WebKit

/// Single typed Swift facade for every JavaScript evaluation against Messenger's
/// `WKWebView`, keeping raw JS strings beside `InjectedScript` instead of
/// scattered across window and bubble controllers.
public final class MessengerPageBridge {
    public private(set) weak var webView: WKWebView?

    /// Encoded once: `setCardThreadMode` runs ~9 times per thread open.
    private static let cardThreadCSSJSON =
        InjectedScript.stringLiteral(InjectedScript.cardThreadCSS) ?? "\"\""

    public init(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: Notifications & Unread

    /// Reopen the thread tied to a clicked native notification.
    /// `completion` gets false when the page no longer knows that notification.
    public func activateNotification(id: Int, completion: ((Bool) -> Void)? = nil) {
        webView?.evaluateJavaScript("window.__plumeActivateNotification(\(id))") { result, _ in
            completion?((result as? Bool) == true)
        }
    }

    /// Count unread chats in the list (facebook.com fallback). Returns nil when
    /// the page reports `-1` (list unavailable) so callers keep their current count.
    public func fetchUnreadCount(completion: @escaping (Int?) -> Void) {
        webView?.evaluateJavaScript("window.__plumeUnreadCount ? window.__plumeUnreadCount() : -1") { result, _ in
            guard let n = (result as? NSNumber)?.intValue, n >= 0 else {
                completion(nil)
                return
            }
            completion(n)
        }
    }

    // MARK: Styles

    public func setStyle(id: String, css: String) {
        guard let idJSON = InjectedScript.stringLiteral(id),
              let cssJSON = InjectedScript.stringLiteral(css) else { return }
        webView?.evaluateJavaScript("window.__plumeSetStyle(\(idJSON), \(cssJSON))",
                                    completionHandler: nil)
    }

    public func removeStyle(id: String) {
        guard let idJSON = InjectedScript.stringLiteral(id) else { return }
        webView?.evaluateJavaScript("window.__plumeRemoveStyle(\(idJSON))",
                                    completionHandler: nil)
    }

    /// Toggle the bubble card's sidebar/top-bar hiding stylesheet.
    public func setCardThreadMode(active: Bool) {
        let flag = active ? "true" : "false"
        let js = """
        try {
          document.documentElement.classList.toggle("plume-card-thread", \(flag));
        } catch (e) {}
        if (\(flag)) {
          window.__plumeSetStyle && window.__plumeSetStyle("\(InjectedScript.StyleID.cardThread)", \(Self.cardThreadCSSJSON));
        } else {
          window.__plumeRemoveStyle && window.__plumeRemoveStyle("\(InjectedScript.StyleID.cardThread)");
        }
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Conversations

    /// Read Messenger's conversation list once, on demand. Deliberately a
    /// snapshot and not an observer: the bubbles only need this when they are
    /// built or when the picker opens.
    public func fetchConversations(limit: Int,
                                   completion: @escaping ([BubbleConversation]) -> Void) {
        guard let webView else { completion([]); return }
        webView.evaluateJavaScript("window.__plumeConvList(\(max(1, limit)))") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([BubbleConversation.Raw].self, from: data)
            else { completion([]); return }
            completion(raw.compactMap(BubbleConversation.init(raw:)))
        }
    }

    public func expandConversationList(completion: @escaping () -> Void) {
        guard let webView else { completion(); return }
        webView.evaluateJavaScript("window.__plumeExpandConvList && window.__plumeExpandConvList()") { _, _ in
            completion()
        }
    }

    public func deleteThread(url: URL, completion: @escaping (ThreadDeleteOutcome) -> Void) {
        guard let webView else { completion(.failed); return }
        webView.callAsyncJavaScript(InjectedScript.deleteThreadJS,
                                    arguments: ["href": url.absoluteString],
                                    in: nil, in: .page) { result in
            completion(ThreadDeleteOutcome(result: try? result.get()))
        }
    }

    public func runConversationAction(_ call: String) {
        webView?.evaluateJavaScript(
            "try{window.__plumeConv&&window.__plumeConv.\(call)}catch(e){}",
            completionHandler: nil
        )
    }

    public func triggerNewMessage(completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.evaluateJavaScript(
            "(function(){try{return !!(window.__plumeConv&&window.__plumeConv.newMessage())}catch(e){return false}})()"
        ) { result, _ in
            completion((result as? Bool) == true)
        }
    }

    // MARK: Bubble card helpers

    public func injectThreadHelpers(completion: @escaping () -> Void) {
        guard let webView else { completion(); return }
        webView.evaluateJavaScript(InjectedScript.threadHelpersJS) { _, _ in
            completion()
        }
    }

    public func openThread(url: URL, force: Bool, completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.callAsyncJavaScript("return await window.__plumeOpenThreadRetry(href, force);",
                                    arguments: ["href": url.absoluteString, "force": force],
                                    in: nil, in: .page) { result in
            completion((try? result.get()) as? Bool ?? false)
        }
    }

    public func scrollToLatest(completion: @escaping (_ settled: Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.evaluateJavaScript("window.__plumeScrollToLatest && window.__plumeScrollToLatest()") { result, _ in
            completion((result as? String) == "settled")
        }
    }

    public func hideSkipLinks() {
        webView?.evaluateJavaScript("window.__plumeHideSkipLinks && window.__plumeHideSkipLinks()",
                                    completionHandler: nil)
    }

    public func detectTheater(completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.evaluateJavaScript("window.__plumeDetectTheater&&window.__plumeDetectTheater()") { result, _ in
            completion((result as? Bool) == true)
        }
    }
}
