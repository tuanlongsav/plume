import Foundation

/// The unread count the page title carries, or nil when the title says
/// nothing about it.
///
/// Messenger writes the count as a leading "(N)" — "(3) Messenger". While a
/// new message is waiting in the background it also flashes the title to a
/// sender line ("An sent you a message"), which has no count at all. Read as
/// zero, every flash blanked the dock badge and re-badged the bubble chain
/// (and, after the debounce, re-read the whole inbox); nil keeps the last
/// count instead.
public enum UnreadTitle {
    public static func count(from title: String?) -> Int? {
        guard let title else { return nil }
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            let inside = title[title.index(after: title.startIndex)..<close]
            if !inside.isEmpty, inside.allSatisfy({ $0.isASCII && $0.isNumber }),
               let n = Int(inside) {
                return n
            }
        }
        // The app's own resting title, with no count: nothing unread.
        let lower = title.lowercased()
        if lower.contains("messenger") || lower.contains("facebook") { return 0 }
        return nil
    }
}

/// Shared unread count formatting for the Dock icon, menu bar icon and app chip.
public enum UnreadBadge {
    /// Messenger encodes the unread count as a *leading* "(N)" in the page
    /// title, e.g. "(3) Messenger". Falls back to 0 when no count is present.
    public static func count(from title: String?) -> Int {
        UnreadTitle.count(from: title) ?? 0
    }

    /// Dock, menu bar and app-chip badge text: nothing at zero, capped at
    /// "99+", and nothing at all while the user has asked for no count
    /// (`Preferences.hideUnreadCount`). Notifications are unaffected.
    public static func label(_ count: Int, hidden: Bool = false) -> String? {
        guard !hidden else { return nil }
        return count > 99 ? "99+" : (count > 0 ? String(count) : nil)
    }
}

/// Stable identifiers for delivered `UNNotificationRequest`s.
public enum NotificationID {
    /// The web `tag` names a notification that a newer one with the same tag
    /// replaces (one entry per conversation, updated). Keyed by instance id
    /// alone, a burst of messages piled up as separate banners.
    public static func identifier(id: Int, tag: String?, fromPopup: Bool = false) -> String {
        let prefix = fromPopup ? "plume-popup-" : "plume-"
        if let tag, !tag.isEmpty { return prefix + "tag-" + tag }
        return prefix + "\(id)"
    }
}
