import Foundation

/// Parsing and rebuilding of Messenger conversation URLs.
///
/// Kept free of AppKit so it can be unit-tested: we can't log into Messenger
/// here, so this pure seam is the only part of the bubble feature we can prove
/// correct automatically.
enum ThreadURL {
    /// Thread namespaces messenger.com uses. A conversation lives under one of
    /// these, followed by its id.
    private static let prefixes = ["/t/", "/e2ee/t/", "/marketplace/t/"]

    /// True when `url` points at a specific conversation rather than the
    /// inbox/list. Drives whether the bubble hides Messenger's sidebar.
    static func isThread(_ url: URL?) -> Bool { canonical(from: url) != nil }

    /// Normalise an open Messenger URL to a clean thread URL — same namespace,
    /// id only, no tracking query. Returns nil when `url` isn't a conversation.
    static func canonical(from url: URL?) -> URL? {
        guard let url,
              let host = url.host?.lowercased(),
              host == "messenger.com" || host.hasSuffix(".messenger.com")
        else { return nil }

        for prefix in prefixes where url.path.hasPrefix(prefix) {
            let rest = url.path.dropFirst(prefix.count)
            guard let id = rest.split(separator: "/").first.map(String.init),
                  !id.isEmpty
            else { return nil }
            return URL(string: "https://www.messenger.com\(prefix)\(id)/")
        }
        return nil
    }

    /// The conversation id alone — the same thread can be listed under `/t/`
    /// in one place and `/e2ee/t/` in another, so compare threads by this,
    /// never by URL.
    static func id(from url: URL?) -> String? {
        canonical(from: url)?.pathComponents.last { $0 != "/" }
    }
}
