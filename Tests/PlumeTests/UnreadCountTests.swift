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

    // Dock and app chip share this, so both show the same text.
    func testBadgeLabel() {
        XCTAssertNil(WebViewController.badgeLabel(0))
        XCTAssertNil(WebViewController.badgeLabel(-1))
        XCTAssertEqual(WebViewController.badgeLabel(7), "7")
        XCTAssertEqual(WebViewController.badgeLabel(99), "99")
        XCTAssertEqual(WebViewController.badgeLabel(100), "99+")
    }
}
