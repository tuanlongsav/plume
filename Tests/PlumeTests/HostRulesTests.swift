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
}
