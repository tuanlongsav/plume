import Foundation

/// A WebKit content blocker for third-party ad and analytics hosts.
///
/// Messenger itself loads almost nothing from outside Meta, but what a chat
/// embeds (a shared video's player, a link preview opened in a call window)
/// can pull in ad networks and analytics. Those requests are blocked when
/// third-party to the page. Deliberately a short list of hosts that are
/// trackers and nothing else: no Meta host, nothing a page needs to render,
/// so the blocker cannot break Messenger (`TrackerRulesTests` holds that).
enum TrackerRules {
    /// WebKit caches compiled lists by identifier; bump it with the list.
    static let identifier = "plume.trackers.1"

    static let hosts: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "scorecardresearch.com", "amazon-adsystem.com",
        "adnxs.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "hotjar.com", "mixpanel.com", "segment.io", "quantserve.com",
        "moatads.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com",
        "openx.net", "bat.bing.com", "clarity.ms", "analytics.tiktok.com",
    ]

    /// The host and any subdomain of it, nothing that merely ends in the same
    /// letters (`notdoubleclick.net`). WebKit's rule regexes have no `|`, so
    /// it is one rule per host; this is the usual adblock-to-WebKit form.
    static func urlFilter(for host: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
    }

    /// The encoded rule list for `WKContentRuleListStore`.
    static func json() -> String {
        let rules: [[String: Any]] = hosts.map { host in
            ["trigger": ["url-filter": urlFilter(for: host), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
