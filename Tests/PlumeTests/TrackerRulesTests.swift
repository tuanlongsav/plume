import XCTest
@testable import Plume

final class TrackerRulesTests: XCTestCase {

    private func blocked(_ url: String) -> Bool {
        TrackerRules.hosts.contains { host in
            let re = try! NSRegularExpression(pattern: TrackerRules.urlFilter(for: host))
            return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    func testBlocksTheHostAndItsSubdomains() {
        XCTAssertTrue(blocked("https://doubleclick.net/x"))
        XCTAssertTrue(blocked("https://ad.doubleclick.net/ddm/x"))
        XCTAssertTrue(blocked("https://www.google-analytics.com:443/collect"))
        XCTAssertTrue(blocked("https://bat.bing.com/action/0"))
    }

    func testLeavesLookAlikesAndMessengerAlone() {
        for url in ["https://notdoubleclick.net/x", "https://doubleclick.net.example.com/x",
                    "https://www.bing.com/search?q=doubleclick.net",
                    "https://www.facebook.com/messages/t/1/", "https://www.messenger.com/",
                    "https://scontent.xx.fbcdn.net/v/x.jpg", "https://cdn.fbsbx.com/v/doc.pdf",
                    "https://www.youtube.com/embed/x"] {
            XCTAssertFalse(blocked(url), url)
        }
    }

    // The blocker must never touch what Messenger needs: no host that the
    // app treats as its own, its attachment CDN, or another Meta service.
    func testNoMetaHostIsListed() {
        let meta = ["instagram.com", "whatsapp.net", "whatsapp.com", "meta.com", "fb.com", "fb.me"]
        for host in TrackerRules.hosts {
            XCTAssertFalse(Plume.isInternal(host: host), host)
            XCTAssertFalse(Plume.isAttachmentHost(URL(string: "https://\(host)/")!), host)
            XCTAssertFalse(meta.contains { host == $0 || host.hasSuffix("." + $0) }, host)
        }
    }

    func testEncodedListIsOneThirdPartyBlockPerHost() throws {
        let data = Data(TrackerRules.json().utf8)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, TrackerRules.hosts.count)
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
            XCTAssertNotNil(trigger["url-filter"] as? String)
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
        }
    }
}
