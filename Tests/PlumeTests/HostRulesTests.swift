import XCTest
@testable import Plume

final class HostRulesTests: XCTestCase {

    func testInternalMatchesExactAndSubdomains() {
        XCTAssertTrue(Plume.isInternal(host: "messenger.com"))
        XCTAssertTrue(Plume.isInternal(host: "www.messenger.com"))
        XCTAssertTrue(Plume.isInternal(host: "chat.messenger.com"))
        XCTAssertTrue(Plume.isInternal(host: "MESSENGER.COM"))       // case-insensitive
        XCTAssertTrue(Plume.isInternal(host: "facebook.com"))
        XCTAssertTrue(Plume.isInternal(host: "fbcdn.net"))
        XCTAssertTrue(Plume.isInternal(host: "static.fbcdn.net"))
    }

    func testInternalRejectsLookAlikes() {
        XCTAssertFalse(Plume.isInternal(host: "evilmessenger.com"))
        XCTAssertFalse(Plume.isInternal(host: "messenger.com.evil.com"))
        XCTAssertFalse(Plume.isInternal(host: "fbcdn.net.evil.com"))
        XCTAssertFalse(Plume.isInternal(host: "example.com"))
        XCTAssertFalse(Plume.isInternal(host: ""))
    }

    // Media auto-grant must be strictly narrower than the navigation allowlist.
    func testCallOriginIsNarrow() {
        XCTAssertTrue(Plume.isCallOrigin(host: "messenger.com"))
        XCTAssertTrue(Plume.isCallOrigin(host: "www.messenger.com"))
        XCTAssertTrue(Plume.isCallOrigin(host: "facebook.com"))
        XCTAssertTrue(Plume.isCallOrigin(host: "web.facebook.com"))

        // CDN / other internal hosts are internal for navigation but must NOT
        // be silently granted camera/mic.
        XCTAssertFalse(Plume.isCallOrigin(host: "fbcdn.net"))
        XCTAssertFalse(Plume.isCallOrigin(host: "static.fbcdn.net"))
        XCTAssertFalse(Plume.isCallOrigin(host: "l.facebook.com.evil.com"))
        XCTAssertFalse(Plume.isCallOrigin(host: "evilmessenger.com"))
    }

    // Attachment CDN detection drives in-app download/PDF viewing.
    func testAttachmentHostDetection() {
        XCTAssertTrue(Plume.isAttachmentHost(URL(string: "https://cdn.fbsbx.com/v/t59.2708-21/x/doc.pdf?dl=1")!))
        XCTAssertTrue(Plume.isAttachmentHost(URL(string: "https://attachment.fbsbx.com/file_download.php?id=1")!))
        XCTAssertTrue(Plume.isAttachmentHost(URL(string: "https://fbsbx.com/x")!))

        // Inline media CDN and look-alikes are NOT attachment hosts.
        XCTAssertFalse(Plume.isAttachmentHost(URL(string: "https://scontent-xx.fbcdn.net/x.jpg")!))
        XCTAssertFalse(Plume.isAttachmentHost(URL(string: "https://www.messenger.com/")!))
        XCTAssertFalse(Plume.isAttachmentHost(URL(string: "https://fbsbx.com.evil.com/x")!))
    }

    // Regression: the attachment CDN must stay OUT of the navigation/call
    // allowlists, or fbsbx traffic would wrongly load in-frame / get media.
    func testAttachmentHostIsNotInternalOrCall() {
        XCTAssertFalse(Plume.isInternal(host: "cdn.fbsbx.com"))
        XCTAssertFalse(Plume.isCallOrigin(host: "cdn.fbsbx.com"))
    }

    // Regression: links in messages go through the l.php shim, whose host is
    // internal. It must count as outbound or the target loads in the app.
    func testLinkShimIsOutbound() {
        let shim = URL(string: "https://l.messenger.com/l.php?u=https%3A%2F%2Fexample.com%2F&h=AT0")!
        XCTAssertTrue(Plume.isLinkShim(shim))
        XCTAssertFalse(Plume.isInternal(shim))
        XCTAssertFalse(Plume.isInternal(URL(string: "https://l.facebook.com/l.php?u=x")!))
        XCTAssertFalse(Plume.isInternal(URL(string: "https://lm.facebook.com/l.php?u=x")!))

        // The rest of those hosts, and real Messenger pages, stay internal.
        XCTAssertTrue(Plume.isInternal(URL(string: "https://l.messenger.com/other")!))
        XCTAssertTrue(Plume.isInternal(URL(string: "https://www.messenger.com/t/123/")!))
        XCTAssertFalse(Plume.isLinkShim(URL(string: "https://l.messenger.com.evil.com/l.php?u=x")!))
    }

    func testUnwrapLinkShim() {
        let shim = URL(string: "https://l.messenger.com/l.php?u=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2&h=AT0")!
        XCTAssertEqual(Plume.unwrapLinkShim(shim).absoluteString, "https://example.com/a?b=1&c=2")
        let fb = URL(string: "https://l.facebook.com/l.php?u=http%3A%2F%2Fexample.org%2F&h=x")!
        XCTAssertEqual(Plume.unwrapLinkShim(fb).absoluteString, "http://example.org/")

        // Not a shim, or no usable http(s) target: handed back unchanged.
        for s in ["https://www.messenger.com/t/1/",
                  "https://l.messenger.com/l.php?h=AT0",
                  "https://l.messenger.com/l.php?u=javascript%3Aalert(1)",
                  "https://l.messenger.com/l.php?u=not%20a%20url",
                  "https://l.messenger.com.evil.com/l.php?u=https%3A%2F%2Fexample.com%2F"] {
            let url = URL(string: s)!
            XCTAssertEqual(Plume.unwrapLinkShim(url), url, s)
        }
    }

    // Messenger opens its call window on about:blank and navigates it after;
    // a nil from createWebViewWith made window.open return null.
    func testPopupRules() {
        XCTAssertTrue(Plume.opensInPopup(nil))
        XCTAssertTrue(Plume.opensInPopup(URL(string: "about:blank")!))
        XCTAssertTrue(Plume.opensInPopup(URL(string: "https://www.messenger.com/groupcall/ROOM:1/?call_id=2")!))
        XCTAssertTrue(Plume.opensInPopup(URL(string: "https://www.facebook.com/videocall/incall/")!))

        XCTAssertFalse(Plume.opensInPopup(URL(string: "https://cdn.fbsbx.com/v/doc.pdf")!))
        XCTAssertFalse(Plume.opensInPopup(URL(string: "https://example.com/")!))
        XCTAssertFalse(Plume.opensInPopup(URL(string: "https://messenger.com.evil.com/")!))
        XCTAssertFalse(Plume.opensInPopup(URL(string: "https://l.messenger.com/l.php?u=https%3A%2F%2Fexample.com%2F")!))
    }

    func testOnlyWebAndContactSchemesOpenExternally() {
        for s in ["https://example.com/", "http://example.com/",
                  "mailto:someone@example.com", "tel:+84123456789"] {
            XCTAssertTrue(Plume.isExternallyOpenable(URL(string: s)!), s)
        }
        for s in ["about:blank", "javascript:alert(1)", "file:///etc/hosts",
                  "x-apple.systempreferences:com.apple.preference.security"] {
            XCTAssertFalse(Plume.isExternallyOpenable(URL(string: s)!), s)
        }
    }
}
