import Foundation

public enum Plume {
    /// The page we wrap. messenger.com serves a full desktop web app; accounts
    /// Meta has moved to facebook.com start at `facebookMessagesURL` instead.
    public static let homeURL = URL(string: "https://www.messenger.com/")!

    /// Where Messenger lives for accounts Meta has moved into Facebook
    /// (from April 2026). Same app, same roles, under facebook.com's top bar.
    public static let facebookMessagesURL = URL(string: "https://www.facebook.com/messages/")!

    /// Where the app starts: the site the account was last seen on.
    public static var startURL: URL {
        Preferences.messengerSite == .facebook ? facebookMessagesURL : homeURL
    }

    /// A current desktop Safari UA so Facebook serves the full-featured
    /// desktop site (and not a degraded / "please upgrade" page).
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Safari/605.1.15"

    /// Registrable domains we keep *inside* the app. Anything else opens in the
    /// user's default browser instead of hijacking our window. `matches`
    /// suffix-tests subdomains, so `www.`/`m.`/`l.`/`accountscenter.` etc. are
    /// all covered by the parent domain — no need to list them.
    public static let internalHosts: Set<String> = [
        "messenger.com",
        "facebook.com",
        "fbcdn.net",
    ]

    /// A link shim is outbound by definition, even though its host is ours.
    public static func isInternal(_ url: URL) -> Bool {
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

    public static func isLinkShim(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return linkShimHosts.contains(host) && url.path == "/l.php"
    }

    /// A URL from a string that may hold characters a URL cannot, the same
    /// way on every macOS. macOS 13's `URL(string:)` returns nil for
    /// "https://vi.wikipedia.org/wiki/Việt_Nam"; macOS 14's encodes it but
    /// also turns an existing "%20" into "%2520", a different address. So
    /// encode first, leaving `%` escapes and URL punctuation alone.
    public static func lenientURL(_ string: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.formUnion(.urlPathAllowed)
        allowed.formUnion(.urlFragmentAllowed)
        allowed.insert(charactersIn: "#%")
        return string.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
            ?? URL(string: string)
    }

    /// The shim's real destination, so the browser opens the site itself
    /// rather than a tracking redirect. Anything that is not a well-formed
    /// http(s) target is returned unchanged; the browser can still follow it.
    public static func unwrapLinkShim(_ url: URL) -> URL {
        guard isLinkShim(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value,
              let target = lenientURL(raw), target.host != nil,
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return url }
        return target
    }

    /// What a `window.open` / `target=_blank` request gets a real window for:
    /// our own pages, and the blank page Messenger opens a call window on
    /// before navigating it. Attachments and the rest of the web do not.
    public static func opensInPopup(_ url: URL?) -> Bool {
        guard let url else { return true }
        if url.scheme?.lowercased() == "about" { return true }
        return isInternal(url)
    }

    /// Schemes worth handing to `NSWorkspace`. Everything else a page can put
    /// in a link (`about:`, `javascript:`, `file:`, custom app schemes) is
    /// dropped rather than launched on the user's behalf.
    public static func isExternallyOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel"].contains(scheme)
    }

    /// Host-based membership test. Accepts the exact host or any subdomain of
    /// a registrable domain in `internalHosts`; the leading dot keeps
    /// look-alikes like `evilmessenger.com` out.
    public static func isInternal(host: String) -> Bool {
        matches(host, in: internalHosts)
    }

    /// Origins allowed to *silently* obtain camera/mic for calls. Deliberately
    /// narrower than `internalHosts`: only the app surfaces that actually place
    /// calls. A CDN such as `fbcdn.net` never needs capture, so auto-granting
    /// it would be needlessly broad — those origins fall through to the normal
    /// WebKit prompt instead.
    public static let callHosts: Set<String> = ["messenger.com", "facebook.com"]

    public static func isCallOrigin(host: String) -> Bool {
        matches(host, in: callHosts)
    }

    /// Silent camera/mic only when the top-level page AND the frame asking
    /// are call surfaces. `origin` is the top-level document's, so judged on
    /// its own a third-party frame embedded in messenger.com passed as ours.
    public static func shouldAutoGrantCapture(originHost: String, frameHost: String) -> Bool {
        isCallOrigin(host: originHost) && isCallOrigin(host: frameHost)
    }

    /// File-attachment CDN. Deliberately SEPARATE from `internalHosts` and from
    /// `fbcdn.net` (the inline image/video CDN): `fbsbx.com` serves user file
    /// attachments with `Content-Disposition: attachment`. It must stay OUT of
    /// `internalHosts` — otherwise `isInternal` would route all fbsbx traffic
    /// into the main frame and break the outbound handoff and media-grant
    /// scoping. The suffix rule covers `cdn.fbsbx.com` / `attachment.fbsbx.com`.
    public static let attachmentHosts: Set<String> = ["fbsbx.com"]

    public static func isAttachmentHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return matches(host, in: attachmentHosts)
    }

    private static func matches(_ host: String, in hosts: Set<String>) -> Bool {
        let host = host.lowercased()
        if hosts.contains(host) { return true }
        return hosts.contains { host.hasSuffix("." + $0) }
    }
}
