import Foundation
import PlumeCore
import WebKit

/// Abstraction over Messenger's live web view so `PlumeBubble` operates
/// without importing `PlumeWeb` or embedding raw JavaScript strings.
public protocol BubblePageBridge: AnyObject {
    var webView: WKWebView { get }
    func fetchConversations(limit: Int, completion: @escaping ([BubbleConversation]) -> Void)
    func expandConversationList(completion: @escaping () -> Void)
    func deleteConversation(_ conversation: BubbleConversation, completion: @escaping (Bool) -> Void)
    func setCardThreadMode(active: Bool)
    func injectThreadHelpers(completion: @escaping () -> Void)
    func openThread(url: URL, force: Bool, completion: @escaping (Bool) -> Void)
    func scrollToLatest(completion: @escaping (_ settled: Bool) -> Void)
    func hideSkipLinks()
    func detectTheater(completion: @escaping (Bool) -> Void)
}
