import AppKit
import PlumeBubble
import PlumeCore
import PlumeUI
import PlumeWeb
import WebKit

/// Thin adapter exposing `WebViewController` + `MessengerPageBridge` to
/// `PlumeBubble` without coupling `PlumeBubble` directly to `PlumeWeb`.
final class MainBubblePageBridge: BubblePageBridge {
    let webView: WKWebView
    private weak var controller: WebViewController?

    init(webView: WKWebView, controller: WebViewController) {
        self.webView = webView
        self.controller = controller
    }

    func fetchConversations(limit: Int, completion: @escaping ([BubbleConversation]) -> Void) {
        guard let controller else { completion([]); return }
        controller.fetchConversations(limit: limit, completion: completion)
    }

    func expandConversationList(completion: @escaping () -> Void) {
        guard let controller else { completion(); return }
        controller.pageBridge.expandConversationList(completion: completion)
    }

    func deleteConversation(_ conversation: BubbleConversation, completion: @escaping (Bool) -> Void) {
        guard let controller else { completion(false); return }
        controller.confirmAndDeleteConversation(
            url: conversation.url, name: conversation.name, completion: completion)
    }

    func setCardThreadMode(active: Bool) {
        controller?.pageBridge.setCardThreadMode(active: active)
    }

    func injectThreadHelpers(completion: @escaping () -> Void) {
        guard let controller else { completion(); return }
        controller.pageBridge.injectThreadHelpers(completion: completion)
    }

    func openThread(url: URL, force: Bool, completion: @escaping (Bool) -> Void) {
        guard let controller else { completion(false); return }
        controller.pageBridge.openThread(url: url, force: force, completion: completion)
    }

    func scrollToLatest(completion: @escaping (_ settled: Bool) -> Void) {
        guard let controller else { completion(false); return }
        controller.pageBridge.scrollToLatest(completion: completion)
    }

    func hideSkipLinks() {
        controller?.pageBridge.hideSkipLinks()
    }

    func detectTheater(completion: @escaping (Bool) -> Void) {
        guard let controller else { completion(false); return }
        controller.pageBridge.detectTheater(completion: completion)
    }
}

/// Manages switching between the main window and bubble mode, including the
/// patient cold-launch restore sequence.
final class BubbleModeCoordinator {
    private unowned let window: NSWindow
    private unowned let controller: WebViewController
    /// Bubble mode is restored once per launch, on the first load that
    /// actually succeeded — `onPageReady`, not `onChromeUpdate`.
    private var didRestoreMode = false

    init(window: NSWindow, controller: WebViewController) {
        self.window = window
        self.controller = controller
    }

    /// Bubble mode replaces the main window rather than sitting alongside it:
    /// the whole point is a compact, private surface, so leaving the full
    /// window on screen would defeat it.
    func toggle() {
        if ChatBubbleController.isOpen { exit(); return }
        enter(announce: true)
    }

    /// Restore the mode the app was last used in. Silent, and patient: on a
    /// cold launch Messenger's conversation list is not there yet, so this is
    /// worth a few quiet retries rather than an alert the user never asked for.
    func restoreLastModeIfNeeded() {
        guard !didRestoreMode else { return }
        didRestoreMode = true
        guard Preferences.bubbleMode, !ChatBubbleController.isOpen else { return }
        enter(announce: false)
    }

    /// Restoring is patient, which means it can still be pending when the user
    /// makes their own decision. Every retry re-reads the preference so a
    /// deliberate "leave bubble mode" is never undone a second later.
    private var restoreStillWanted: Bool {
        Preferences.bubbleMode && !ChatBubbleController.isOpen
    }

    /// `wentToChats`: this attempt sequence loaded the chat list itself, so it
    /// must wait for it even when the user asked, instead of failing at once.
    private func enter(announce: Bool, attempt: Int = 0, wentToChats: Bool = false) {
        var wentToChats = wentToChats
        if controller.isOnLoginPage {
            guard announce else { return }
            showBubbleModeAlert(
                L.t("Hãy đăng nhập Facebook trước", "Log in to Facebook first"),
                L.t("Messenger nằm trong Facebook sau khi bạn đăng nhập. Đăng nhập xong rồi thử lại.",
                    "Messenger is inside Facebook once you are logged in. Log in, then try again.")
            )
            return
        }
        // On facebook.com the window can be on the feed or a profile, which
        // have no chat list to read. Go to the list, then wait for it below.
        if attempt == 0, !ThreadURL.isMessagesSurface(controller.webView.url) {
            controller.goToChats()
            wentToChats = true
        }
        controller.fetchConversations(limit: Preferences.bubbleLimit) { [weak self] convos in
            guard let self, !ChatBubbleController.isOpen else { return }
            // The user may have decided for themselves while this was in flight.
            if !announce, !Preferences.bubbleMode { return }
            // Never hide the main window with nothing to replace it.
            guard !convos.isEmpty else {
                if !announce || wentToChats, attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { return }
                        if announce {
                            guard !ChatBubbleController.isOpen else { return }
                        } else {
                            guard self.restoreStillWanted else { return }
                        }
                        self.enter(announce: announce, attempt: attempt + 1, wentToChats: wentToChats)
                    }
                    return
                }
                guard announce else { return }   // a restore that fails just stays put
                self.showBubbleModeAlert(
                    L.t("Chưa lấy được danh sách hội thoại", "Couldn't read your conversation list"),
                    L.t("Hãy đợi Messenger tải xong danh sách hội thoại rồi thử lại.",
                        "Wait for Messenger's conversation list to finish loading, then try again.")
                )
                return
            }
            // Lend the live web view: Messenger is already up in it, so the
            // first bubble opens instantly instead of booting a second copy.
            guard let lent = self.controller.lendWebView() else { return }
            let bridge = MainBubblePageBridge(webView: lent, controller: self.controller)
            ChatBubbleController.show(
                conversations: convos,
                bridge: bridge,
                onExit: { [weak self] in self?.exit() }
            )
            self.controller.republishUnread()
            self.window.orderOut(nil)
            Preferences.bubbleMode = true
        }
    }

    func exit() {
        Preferences.bubbleMode = false
        ChatBubbleController.hide()
        // Unconditional and idempotent: a main window with no web view in it is
        // the one failure this whole arrangement must never produce.
        controller.reclaimWebView()
        window.makeKeyAndOrderFront(nil)
        // Always the user's request, often from a non-activating bubble panel
        // or the menu bar icon's menu while another app is in front: insist,
        // or the main window can come up behind that app.
        NSApp.plumeActivate(fromShortcut: true)
    }

    private func showBubbleModeAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        AlertPresenter.presentSheetOrModal(
            alert,
            preferredHost: window,
            requireAppActiveForSheet: true,
            activateFromShortcutOnFallback: true
        )
    }
}
