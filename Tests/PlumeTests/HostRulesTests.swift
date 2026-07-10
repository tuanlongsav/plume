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
}
