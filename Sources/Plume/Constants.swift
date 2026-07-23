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
        matches(host, in: internalHosts)
    }

    /// Origins allowed to *silently* obtain camera/mic for calls. Deliberately
    /// narrower than `internalHosts`: only the app surfaces that actually place
    /// calls. A CDN such as `fbcdn.net` never needs capture, so auto-granting
    /// it would be needlessly broad — those origins fall through to the normal
    /// WebKit prompt instead.
    static let callHosts: Set<String> = ["messenger.com", "facebook.com"]

    static func isCallOrigin(host: String) -> Bool {
        matches(host, in: callHosts)
    }

    /// File-attachment CDN. Deliberately SEPARATE from `internalHosts` and from
    /// `fbcdn.net` (the inline image/video CDN): `fbsbx.com` serves user file
    /// attachments with `Content-Disposition: attachment`. It must stay OUT of
    /// `internalHosts` — otherwise `isInternal` would route all fbsbx traffic
    /// into the main frame and break the outbound handoff and media-grant
    /// scoping. The suffix rule covers `cdn.fbsbx.com` / `attachment.fbsbx.com`.
    static let attachmentHosts: Set<String> = ["fbsbx.com"]

    static func isAttachmentHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return matches(host, in: attachmentHosts)
    }

    private static func matches(_ host: String, in hosts: Set<String>) -> Bool {
        let host = host.lowercased()
        if hosts.contains(host) { return true }
        return hosts.contains { host.hasSuffix("." + $0) }
    }
}
