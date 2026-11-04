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

    // Accounts Meta has moved to facebook.com keep the same namespaces under
    // /messages/. Rejecting them emptied the chat list and blocked bubble mode.
    func testFacebookMessagesThreads() {
        func canon(_ s: String) -> URL? { ThreadURL.canonical(from: URL(string: s)!) }
        XCTAssertEqual(canon("https://www.facebook.com/messages/t/123"),
                       URL(string: "https://www.facebook.com/messages/t/123/"))
        XCTAssertEqual(canon("https://www.facebook.com/messages/e2ee/t/9/?entrypoint=x"),
                       URL(string: "https://www.facebook.com/messages/e2ee/t/9/"))
        XCTAssertEqual(canon("https://web.facebook.com/messages/t/5/"),
                       URL(string: "https://web.facebook.com/messages/t/5/"))
        XCTAssertEqual(canon("https://facebook.com/messages/t/5"),
                       URL(string: "https://www.facebook.com/messages/t/5/"))
    }

    // A bubble made while the session was on one site must still match the
    // same chat after Meta moves it to the other.
    func testIdIsSharedAcrossSites() {
        let ids = ["https://www.messenger.com/t/77/",
                   "https://www.facebook.com/messages/t/77/",
                   "https://www.facebook.com/messages/e2ee/t/77?x=1"]
            .map { ThreadURL.id(from: URL(string: $0)) }
        XCTAssertEqual(ids, ["77", "77", "77"])
    }

    func testFacebookNonThreadPages() {
        for s in ["https://www.facebook.com/messages/",
                  "https://www.facebook.com/messages/t/",
                  "https://www.facebook.com/messages/requests/",
                  "https://www.facebook.com/t/123",       // the messenger.com shape, wrong site
                  "https://www.messenger.com/messages/t/1", // the facebook shape, wrong site
                  "https://www.facebook.com/",
                  "https://evilfacebook.com/messages/t/1",
                  "https://facebook.com.evil.com/messages/t/1"] {
            XCTAssertNil(ThreadURL.canonical(from: URL(string: s)!), s)
        }
    }

    // Only the Messenger part of facebook.com has a chat list to read.
    func testMessagesSurface() {
        for s in ["https://www.messenger.com/", "https://www.messenger.com/t/1",
                  "https://www.facebook.com/messages", "https://www.facebook.com/messages/",
                  "https://www.facebook.com/messages/t/1/", "https://web.facebook.com/messages/e2ee/t/2"] {
            XCTAssertTrue(ThreadURL.isMessagesSurface(URL(string: s)!), s)
        }
        for s in ["https://www.facebook.com/", "https://www.facebook.com/home.php",
                  "https://www.facebook.com/login/", "https://www.facebook.com/messagesfoo",
                  "https://www.facebook.com/someone", "https://l.facebook.com/l.php?u=x",
                  "https://l.messenger.com/l.php?u=x", "https://evilfacebook.com/messages/",
                  "https://example.com/messages/"] {
            XCTAssertFalse(ThreadURL.isMessagesSurface(URL(string: s)!), s)
        }
        XCTAssertFalse(ThreadURL.isMessagesSurface(nil))
    }
}
