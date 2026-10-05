import Foundation

/// Whether a `__plumeConvList` snapshot may rewrite the live bubble chain.
///
/// Opening a thread hides Messenger's inbox (CSS) and may reload the SPA.
/// The snapshot then comes back empty or short. Treating that as "the recents
/// list" deletes every contact head and leaves only the app chip.
enum BubbleChainSync {
    static func shouldApplySnapshot(count: Int, contactHeads: Int,
                                    inboxHidden: Bool) -> Bool {
        if count <= 0 { return false }
        if inboxHidden && count < contactHeads { return false }
        return true
    }
}
