import AppKit
import PlumeCore
import UserNotifications
import WebKit

/// Owns the JS→native script-message channels (`notify`, `notifyClose`,
/// `rowMenu`) and synchronises the Dock badge and `.plumeUnreadChanged`
/// broadcast from either the page title (messenger.com) or on-demand unread
/// list counting (facebook.com).
final class WebNotificationBridge: NSObject {
    private weak var webView: WKWebView?
    private weak var pageBridge: MessengerPageBridge?
    private(set) var badgeCount = 0
    private var zeroRecheck: DispatchWorkItem?

    /// Forwarded when the user right-clicks a chat row in the main sidebar.
    var onRowMenu: (([String: Any]) -> Void)?

    /// Attach to `contentController` before the `WKWebView` is created; call
    /// `attach(webView:pageBridge:)` immediately after creation.
    func install(on contentController: WKUserContentController) {
        // One proxy handles every channel; the content controller retains it
        // while the proxy only weakly references us, so there is no cycle.
        let proxy = ScriptMessageProxy(self)
        contentController.add(proxy, name: "notify")
        contentController.add(proxy, name: "notifyClose")
        contentController.add(proxy, name: "rowMenu")
    }

    func attach(webView: WKWebView, pageBridge: MessengerPageBridge) {
        self.webView = webView
        self.pageBridge = pageBridge
    }

    // MARK: Badge

    func updateBadgeFromTitle(_ title: String?) {
        guard ThreadURL.site(of: webView?.url) == .facebook else {
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
        pageBridge?.fetchUnreadCount { [weak self] count in
            guard let self, let n = count else { return }
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

    // Called on the main thread (from title KVO); no dispatch needed.
    private func setBadge(_ count: Int) {
        badgeCount = count
        let label = UnreadBadge.label(count, hidden: Preferences.hideUnreadCount)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        // The chat bubble badges itself from this instead of watching the DOM.
        PlumeUnreadNotification.post(count: count)
    }

    // MARK: Script messages

    fileprivate func receive(message: WKScriptMessage) {
        // Message handlers are reachable from every frame, so an embedded
        // third-party frame could otherwise post spoofed native banners or
        // pop the delete menu. Only our page's own main frame may.
        let frame = message.frameInfo
        guard frame.isMainFrame,
              Plume.isInternal(host: frame.securityOrigin.host),
              let body = message.body as? [String: Any] else { return }
        // Call windows share this content controller, so their notifications
        // arrive here too; dropping them left the page told "granted" and the
        // user told nothing. Only the main page may open the delete menu.
        let fromPopup = message.webView !== webView
        switch message.name {
        case "notify":      handleNotify(body, fromPopup: fromPopup)
        case "notifyClose": handleNotifyClose(body, fromPopup: fromPopup)
        case "rowMenu" where !fromPopup: onRowMenu?(body)
        default: break
        }
    }

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
            identifier: NotificationID.identifier(id: id, tag: body["tag"] as? String,
                                                  fromPopup: fromPopup),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        // A new message may not change the title (facebook.com), so it is a
        // trigger of its own for the badge and the bubble chain.
        updateBadgeFromTitle(webView?.title)
    }

    func handleNotifyClose(_ body: [String: Any], fromPopup: Bool = false) {
        guard let id = body["id"] as? Int else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [NotificationID.identifier(id: id, tag: body["tag"] as? String,
                                                        fromPopup: fromPopup)])
    }
}

/// Thin trampoline so each message-handler name forwards to the bridge
/// without retaining it in a cycle through WKUserContentController.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: WebNotificationBridge?
    init(_ bridge: WebNotificationBridge) { self.bridge = bridge }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        bridge?.receive(message: message)
    }
}
