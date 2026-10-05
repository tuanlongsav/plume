import Foundation

/// What `InjectedScript.deleteThreadJS` reports back. The script drives
/// Messenger's own "Delete chat" flow, so every step that can fail to find its
/// control has a code — and any code but `ok` before the confirm button means
/// nothing was deleted.
enum ThreadDeleteOutcome: String {
    case ok
    /// The conversation's row is not in Messenger's (virtualised) sidebar.
    case noRow = "no-row"
    /// The row has no "⋯" button we recognise.
    case noMenu = "no-menu"
    /// The "⋯" menu opened without a "Delete chat" item.
    case noItem = "no-item"
    /// Messenger's confirmation dialog never appeared.
    case noConfirm = "no-confirm"
    /// Confirm was clicked but the row is still listed.
    case timeout
    /// The script threw, or returned something unexpected.
    case failed

    init(result: Any?) {
        self = (result as? String).flatMap(ThreadDeleteOutcome.init(rawValue:)) ?? .failed
    }

    /// Text for the failure alert; nil when the chat was deleted.
    var failureMessage: String? {
        switch self {
        case .ok:
            return nil
        case .noRow:
            return L.t("Không tìm thấy đoạn chat này trong danh sách của Messenger. Chưa xoá gì.",
                       "This chat isn't in Messenger's list. Nothing was deleted.")
        case .noMenu, .noItem, .noConfirm, .failed:
            return L.t("Messenger có thể đã đổi giao diện nên Plume không tìm được lệnh “Xoá đoạn chat”. Chưa xoá gì.",
                       "Messenger's layout may have changed, so Plume couldn't find “Delete chat”. Nothing was deleted.")
        case .timeout:
            return L.t("Đã gửi lệnh xoá nhưng đoạn chat vẫn còn trong danh sách. Hãy kiểm tra lại trên Messenger.",
                       "The delete was sent, but the chat is still listed. Check Messenger.")
        }
    }
}

extension ThreadURL {
    /// The conversation id alone — the same thread can be listed under `/t/`
    /// in one place and `/e2ee/t/` in another.
    static func id(from url: URL?) -> String? {
        canonical(from: url)?.pathComponents.last { $0 != "/" }
    }
}
