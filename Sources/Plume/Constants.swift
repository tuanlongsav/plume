import Foundation

enum Plume {
    /// The page we wrap. messenger.com serves a full desktop web app.
    static let homeURL = URL(string: "https://www.messenger.com/")!

    /// A current desktop Safari UA so Facebook serves the full-featured
    /// desktop site (and not a degraded / "please upgrade" page).
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Safari/605.1.15"

    /// Hosts we keep *inside* the app. Anything else opens in the
    /// user's default browser instead of hijacking our window.
    static let internalHosts: Set<String> = [
        "messenger.com",
        "www.messenger.com",
        "facebook.com",
        "www.facebook.com",
        "m.facebook.com",
        "l.facebook.com",
        "lm.facebook.com",
        "accountscenter.facebook.com",
        "fbcdn.net",
    ]

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isInternal(host: host)
    }

    /// Host-based membership test. Accepts the exact host or any subdomain of
    /// a registrable domain in `internalHosts`; the leading dot keeps
    /// look-alikes like `evilmessenger.com` out.
    static func isInternal(host: String) -> Bool {
        let host = host.lowercased()
        if internalHosts.contains(host) { return true }
        return internalHosts.contains { host.hasSuffix("." + $0) }
    }
}
