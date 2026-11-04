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
enum UnreadTitle {
    static func count(from title: String?) -> Int? {
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

/// Which unread count to show, from the two signals Plume has.
///
/// messenger.com writes Messenger's own count into the title, so the title
/// wins there. facebook.com does not: its title may carry no count, or a
/// count of Facebook's notifications, so there only the inbox read from the
/// DOM (`__plumeUnreadCount`) counts; while it is not mounted (a load in
/// progress) falling back to that title would flash the wrong number.
/// nil: nothing to go on — keep the last count.
enum UnreadSource {
    static func resolve(onFacebook: Bool, title: Int?, dom: Int?) -> Int? {
        onFacebook ? dom : title
    }
}
