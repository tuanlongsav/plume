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

    /// Registrable domains we keep *inside* the app. Anything else opens in the
    /// user's default browser instead of hijacking our window. `matches`
    /// suffix-tests subdomains, so `www.`/`m.`/`l.`/`accountscenter.` etc. are
    /// all covered by the parent domain — no need to list them.
    static let internalHosts: Set<String> = [
        "messenger.com",
        "facebook.com",
        "fbcdn.net",
    ]

    /// A link shim is outbound by definition, even though its host is ours.
    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isInternal(host: host) && !isLinkShim(url)
    }

    /// Facebook's outbound-link redirector. Links in messages point at
    /// `l.messenger.com/l.php?u=<target>&h=…`, which then redirects to the
    /// real site. Judged by its host the shim looked internal, so outbound
    /// links stayed in the app and a `target=_blank` one was loaded over the
    /// live Messenger page. Caprine strips the same prefix.
    private static let linkShimHosts: Set<String> = [
        "l.messenger.com", "l.facebook.com", "lm.facebook.com",
    ]

    static func isLinkShim(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return linkShimHosts.contains(host) && url.path == "/l.php"
    }

    /// The shim's real destination, so the browser opens the site itself
    /// rather than a tracking redirect. Anything that is not a well-formed
    /// http(s) target is returned unchanged; the browser can still follow it.
    static func unwrapLinkShim(_ url: URL) -> URL {
        guard isLinkShim(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value,
              let target = URL(string: raw), target.host != nil,
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return url }
        return target
    }

    /// What a `window.open` / `target=_blank` request gets a real window for:
    /// our own pages, and the blank page Messenger opens a call window on
    /// before navigating it. Attachments and the rest of the web do not.
    static func opensInPopup(_ url: URL?) -> Bool {
        guard let url else { return true }
        if url.scheme?.lowercased() == "about" { return true }
        return isInternal(url)
    }

    /// Schemes worth handing to `NSWorkspace`. Everything else a page can put
    /// in a link (`about:`, `javascript:`, `file:`, custom app schemes) is
    /// dropped rather than launched on the user's behalf.
    static func isExternallyOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel"].contains(scheme)
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
