import AppKit
import PlumeCore
import PlumeUI
import WebKit

/// Orchestrates Messenger's destructive delete-chat flow from the Conversation
/// menu, sidebar right-click menu, or bubble conversation picker.
final class ThreadDeletionCoordinator: NSObject {
    private weak var webView: WKWebView?
    private weak var pageBridge: MessengerPageBridge?
    /// The sidebar row a native right-click menu is currently open for.
    private var pendingRowDelete: (url: URL, name: String)?

    func attach(webView: WKWebView, pageBridge: MessengerPageBridge) {
        self.webView = webView
        self.pageBridge = pageBridge
    }

    var canDeleteCurrentConversation: Bool { ThreadURL.isThread(webView?.url) }

    /// Menu path: delete the conversation that is open right now.
    func deleteCurrentConversation() {
        guard let url = ThreadURL.canonical(from: webView?.url) else { return }
        // The alert should name who is about to be deleted; the list knows.
        pageBridge?.fetchConversations(limit: 80) { [weak self] convos in
            let id = ThreadURL.id(from: url)
            let name = convos.first { ThreadURL.id(from: $0.url) == id }?.name ?? ""
            self?.confirmAndDeleteConversation(url: url, name: name)
        }
    }

    /// Right-click on a row of Messenger's own sidebar (posted by the page).
    func handleRowMenu(_ body: [String: Any]) {
        guard let href = body["href"] as? String,
              let url = ThreadURL.canonical(from: URL(string: href)),
              let webView, let window = webView.window
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

        AlertPresenter.presentSheetOrModal(
            alert,
            preferredHost: webView?.window,
            holdOverlay: true,
            alwaysLiftFallback: true
        ) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { completion?(false); return }
            self.runDelete(url: url, completion: completion)
        }
    }

    private func runDelete(url: URL, completion: ((Bool) -> Void)?) {
        pageBridge?.deleteThread(url: url) { [weak self] outcome in
            if let message = outcome.failureMessage { self?.showDeleteFailure(message) }
            completion?(outcome == .ok)
        }
    }

    private func showDeleteFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("Chưa xoá được đoạn chat", "Couldn't delete the chat")
        alert.informativeText = message
        AlertPresenter.presentSheetOrModal(
            alert,
            preferredHost: webView?.window,
            alwaysLiftFallback: true
        )
    }
}
