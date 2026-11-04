import Foundation

/// Parsing and rebuilding of Messenger conversation URLs.
///
/// Kept free of AppKit so it can be unit-tested: we can't log into Messenger
/// here, so this pure seam is the only part of the bubble feature we can prove
/// correct automatically.
///
/// Meta retired messenger.com for facebook.com/messages in 2026, so threads
/// now live under `/messages/t/<id>` on facebook.com. The messenger.com forms
/// are still read: some accounts and old links still land there.
enum ThreadURL {
    /// Thread namespaces, each followed by the conversation id.
    private static let facebookPrefixes = ["/messages/t/", "/messages/e2ee/t/"]
    private static let messengerPrefixes = ["/t/", "/e2ee/t/", "/marketplace/t/"]

    /// True when `url` points at a specific conversation rather than the
    /// inbox/list. Drives whether the bubble hides Messenger's sidebar.
    static func isThread(_ url: URL?) -> Bool { canonical(from: url) != nil }

    /// Normalise an open conversation URL to a clean thread URL — same site
    /// and namespace, id only, no tracking query. Returns nil when `url` isn't
    /// a conversation.
    static func canonical(from url: URL?) -> URL? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let origin: String
        let prefixes: [String]
        if host == "facebook.com" || host.hasSuffix(".facebook.com") {
            origin = "https://www.facebook.com"
            prefixes = facebookPrefixes
        } else if host == "messenger.com" || host.hasSuffix(".messenger.com") {
            origin = "https://www.messenger.com"
            prefixes = messengerPrefixes
        } else {
            return nil
        }

        for prefix in prefixes where url.path.hasPrefix(prefix) {
            let rest = url.path.dropFirst(prefix.count)
            guard let id = rest.split(separator: "/").first.map(String.init),
                  !id.isEmpty
            else { return nil }
            return URL(string: "\(origin)\(prefix)\(id)/")
        }
        return nil
    }

    /// The conversation id alone — the same thread can be listed under `/t/`
    /// in one place and `/e2ee/t/` in another, or on either site, so compare
    /// threads by this, never by URL.
    static func id(from url: URL?) -> String? {
        canonical(from: url)?.pathComponents.last { $0 != "/" }
    }
}
