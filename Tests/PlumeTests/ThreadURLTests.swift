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

    // Bubble heads, unread flags and "same bubble twice" compare by this: a
    // chat listed under /t/ is often open under /e2ee/t/.
    func testIdIsSharedAcrossNamespaces() {
        let ids = ["https://www.messenger.com/t/77/",
                   "https://www.messenger.com/e2ee/t/77",
                   "https://www.messenger.com/marketplace/t/77/?x=1"]
            .map { ThreadURL.id(from: URL(string: $0)) }
        XCTAssertEqual(ids, ["77", "77", "77"])
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

/// facebook.com/messages, where Messenger moved in 2026.
final class FacebookThreadURLTests: XCTestCase {

    func testCanonicalisesFacebookThreads() {
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://www.facebook.com/messages/t/123")!),
                       URL(string: "https://www.facebook.com/messages/t/123/"))
        XCTAssertEqual(ThreadURL.canonical(from: URL(string: "https://web.facebook.com/messages/e2ee/t/9/?x=1")!),
                       URL(string: "https://www.facebook.com/messages/e2ee/t/9/"))
    }

    // A thread is the same thread on either site.
    func testIdMatchesAcrossSites() {
        let ids = ["https://www.facebook.com/messages/t/77/",
                   "https://www.facebook.com/messages/e2ee/t/77",
                   "https://www.messenger.com/t/77/"]
            .map { ThreadURL.id(from: URL(string: $0)) }
        XCTAssertEqual(ids, ["77", "77", "77"])
    }

    func testFacebookNonThreadsReturnNil() {
        for s in ["https://www.facebook.com/messages/", "https://www.facebook.com/messages/t/",
                  "https://www.facebook.com/", "https://www.facebook.com/t/1",
                  "https://www.facebook.com/someone", "https://facebook.com.evil.com/messages/t/1",
                  "https://evilfacebook.com/messages/t/1"] {
            XCTAssertNil(ThreadURL.canonical(from: URL(string: s)), s)
        }
    }
}
