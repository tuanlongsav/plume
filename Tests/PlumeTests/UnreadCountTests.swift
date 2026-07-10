import XCTest
@testable import Plume

final class UnreadCountTests: XCTestCase {

    func testParsesLeadingCount() {
        XCTAssertEqual(WebViewController.unreadCount(from: "(3) Messenger"), 3)
        XCTAssertEqual(WebViewController.unreadCount(from: "(150) Messenger"), 150)
    }

    func testZeroWhenNoCount() {
        XCTAssertEqual(WebViewController.unreadCount(from: "Messenger"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: nil), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "(0) Messenger"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "() Messenger"), 0)
    }

    // Only a *leading* all-digit "(N)" counts — unrelated parentheses do not.
    func testIgnoresNonLeadingOrNonNumericParens() {
        XCTAssertEqual(WebViewController.unreadCount(from: "Messenger (Work)"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "Foo (12) Bar"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "(a3) Messenger"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "(12"), 0)   // no closing paren
    }
}
