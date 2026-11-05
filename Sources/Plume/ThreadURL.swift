import Foundation

/// Parsing and rebuilding of Messenger conversation URLs.
///
/// Kept free of AppKit so it can be unit-tested: we can't log into Messenger
/// here, so this pure seam is the only part of the bubble feature we can prove
/// correct automatically.
///
/// Messenger lives on two sites. messenger.com puts a conversation at the
/// path root (`/t/<id>`). Since Meta folded Messenger into Facebook (April
/// 2026) moved accounts land on facebook.com, where the same namespaces sit
/// under `/messages/`. Accepting only the first made every row of a moved
/// account's chat list unreadable, and bubble mode refused to start.
enum ThreadURL {
    /// Thread namespaces, relative to the site's messages root. A
    /// conversation lives under one of these, followed by its id.
    private static let namespaces = ["t/", "e2ee/t/", "marketplace/t/"]

    enum Site: Equatable {
        case messenger, facebook

        /// Where conversations start on this site.
        var messagesRoot: String { self == .messenger ? "/" : "/messages/" }
    }

    /// Which Messenger site `url` is on. Suffix-matched with a leading dot,
    /// like the host allowlists, so look-alikes such as `evilfacebook.com`
    /// are neither.
    static func site(of url: URL?) -> Site? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host == "messenger.com" || host.hasSuffix(".messenger.com") { return .messenger }
        if host == "facebook.com" || host.hasSuffix(".facebook.com") { return .facebook }
        return nil
    }

    /// True when `url` points at a specific conversation rather than the
    /// inbox/list. Drives whether the bubble hides Messenger's sidebar.
    static func isThread(_ url: URL?) -> Bool { canonical(from: url) != nil }

    /// True when the page is Messenger itself: anywhere on messenger.com, or
    /// facebook.com's `/messages` section. The feed, a profile or the login
    /// page on facebook.com is not, and has no chat list to read.
    static func isMessagesSurface(_ url: URL?) -> Bool {
        guard let url, let site = site(of: url), !Plume.isLinkShim(url) else { return false }
        switch site {
        case .messenger: return true
        case .facebook: return url.path == "/messages" || url.path.hasPrefix("/messages/")
        }
    }

    /// Normalise an open Messenger URL to a clean thread URL — same site, same
    /// namespace, id only, no tracking query. Returns nil when `url` isn't a
    /// conversation. The site is kept: a thread URL is only ever loaded where
    /// the session already lives, and messenger.com is gone for moved accounts.
    static func canonical(from url: URL?) -> URL? {
        guard let url, let site = site(of: url), let host = url.host?.lowercased() else { return nil }
        let root = site.messagesRoot
        guard url.path.hasPrefix(root) else { return nil }
        let tail = url.path.dropFirst(root.count)
        for namespace in namespaces where tail.hasPrefix(namespace) {
            let rest = tail.dropFirst(namespace.count)
            guard let id = rest.split(separator: "/").first.map(String.init),
                  !id.isEmpty
            else { return nil }
            let origin: String
            switch site {
            case .messenger: origin = "https://www.messenger.com"
            // www. and web. both serve it; a bare domain redirects to www.
            case .facebook: origin = "https://" + (host == "facebook.com" ? "www.facebook.com" : host)
            }
            return URL(string: "\(origin)\(root)\(namespace)\(id)/")
        }
        return nil
    }

    /// The conversation id alone — the same thread can be listed under `/t/`
    /// in one place and `/e2ee/t/` in another, and on either site, so compare
    /// threads by this, never by URL.
    static func id(from url: URL?) -> String? {
        canonical(from: url)?.pathComponents.last { $0 != "/" }
    }

    /// The compose page on the site the session lives on (`/new/` on
    /// messenger.com, `/messages/new/` on facebook.com), for when Messenger's
    /// own "New message" control cannot be found to click. nil off both sites.
    static func newMessageURL(from url: URL?) -> URL? {
        guard let url, let site = site(of: url), let host = url.host?.lowercased() else { return nil }
        switch site {
        case .messenger:
            return URL(string: "https://www.messenger.com/new/")
        case .facebook:
            let origin = "https://" + (host == "facebook.com" ? "www.facebook.com" : host)
            return URL(string: origin + "/messages/new/")
        }
    }
}
