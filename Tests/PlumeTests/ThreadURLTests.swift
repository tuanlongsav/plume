import XCTest
@testable import Plume

final class ThreadURLTests: XCTestCase {

    func testCanonicalisesEachThreadNamespace() {
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/t/123")!),
                       URL(string: "https://www.messenger.com/t/123/"))
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/e2ee/t/9/")!),
                       URL(string: "https://www.messenger.com/e2ee/t/9/"))
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/marketplace/t/5/")!),
                       URL(string: "https://www.messenger.com/marketplace/t/5/"))
    }

    func testStripsTrackingQueryAndTrailingSegments() {
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/t/42/?entrypoint=x")!),
                       URL(string: "https://www.messenger.com/t/42/"))
    }

    // The inbox is not a thread — this is what keeps the sidebar visible so the
    // user can pick someone.
    func testNonThreadUrlsReturnNil() {
        XCTAssertNil(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/")!))
        XCTAssertNil(ThreadURL.canonical(from: URL(string: "https://www.messenger.com/t/")!))
        XCTAssertNil(ThreadURL.canonical(from: nil))
    }

    // Same look-alike guard the host allowlists use.
    func testRejectsLookAlikeHosts() {
        XCTAssertNil(ThreadURL.canonical(from: URL(string: "https://evilmessenger.com/t/1")!))
        XCTAssertNil(ThreadURL.canonical(from: URL(string: "https://messenger.com.evil.com/t/1")!))
    }

    func testIsThread() {
        XCTAssertTrue(ThreadURL.isThread(URL(string: "https://www.messenger.com/t/7")!))
        XCTAssertFalse(ThreadURL.isThread(URL(string: "https://www.messenger.com/")!))
    }
}
