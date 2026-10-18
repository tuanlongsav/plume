import Foundation

/// Whether a `__plumeConvList` snapshot may rewrite the live bubble chain,
/// and what the chain should look like when it does.
enum BubbleChainSync {
    /// Opening a thread hides Messenger's inbox (CSS) and may reload the SPA.
    /// The snapshot then comes back empty or short. Treating that as "the
    /// recents list" deletes every contact head and leaves only the app chip.
    static func shouldApplySnapshot(count: Int, contactHeads: Int,
                                    inboxHidden: Bool) -> Bool {
        if count <= 0 { return false }
        if inboxHidden && count < contactHeads { return false }
        return true
    }

    /// The newest `limit` distinct thread ids of a snapshot.
    static func recentWindow(_ recents: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(recents.filter { seen.insert($0).inserted }.prefix(max(0, limit)))
    }

    /// Contact-head order (newest first, app chip excluded) after a snapshot.
    ///
    /// The newest `limit` recents fill the chain in rank order. Heads the user
    /// opened from the picker (`pinned`) stay even when they are older than
    /// that window, at the slot they hold in `current` — dropping them made a
    /// just-opened head vanish on the next title change. Over the limit,
    /// recents leave from the tail before pinned heads do.
    static func merge(current: [String], recents: [String],
                      pinned: Set<String>, limit: Int) -> [String] {
        var result = recentWindow(recents, limit: limit)
        let window = Set(result)
        var kept = Set<String>()
        for (slot, id) in current.enumerated()
        where pinned.contains(id) && !window.contains(id) && !kept.contains(id) {
            result.insert(id, at: min(slot, result.count))
            kept.insert(id)
        }
        while result.count > max(0, limit) {
            if let i = result.lastIndex(where: { !kept.contains($0) }) {
                result.remove(at: i)
            } else {
                result.removeLast()
            }
        }
        return result
    }
}
