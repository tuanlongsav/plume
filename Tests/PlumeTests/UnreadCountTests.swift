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

    // "Hide Unread Count" blanks every badge, whatever the count.
    func testHiddenBadgeShowsNothing() {
        for count in [0, 1, 42, 500] {
            XCTAssertNil(WebViewController.badgeLabel(count, hidden: true), "\(count)")
        }
    }

    // On facebook.com the title is only a trigger (its count includes
    // notifications); these pin what the parser itself does with those titles.
    func testFacebookTitleShapes() {
        XCTAssertEqual(WebViewController.unreadCount(from: "(3) Facebook"), 3)
        XCTAssertEqual(WebViewController.unreadCount(from: "(3) Messenger | Facebook"), 3)
        XCTAssertEqual(WebViewController.unreadCount(from: "Facebook"), 0)
        XCTAssertEqual(WebViewController.unreadCount(from: "An messaged you"), 0)
    }
}

final class UnreadTitleTests: XCTestCase {

    func testCountFromLeadingParens() {
        XCTAssertEqual(UnreadTitle.count(from: "(3) Messenger"), 3)
        XCTAssertEqual(UnreadTitle.count(from: "(12) Facebook"), 12)
    }

    func testRestingTitleMeansNothingUnread() {
        XCTAssertEqual(UnreadTitle.count(from: "Messenger"), 0)
        XCTAssertEqual(UnreadTitle.count(from: "Messenger | Facebook"), 0)
        XCTAssertEqual(UnreadTitle.count(from: "Messenger (Work)"), 0)
    }

    // Messenger flashes the title to a sender line while a message waits;
    // that says nothing about the count, so the badge must keep its value.
    func testFlashTitleIsUnknown() {
        XCTAssertNil(UnreadTitle.count(from: "An sent you a message"))
        XCTAssertNil(UnreadTitle.count(from: "An đã gửi cho bạn một tin nhắn"))
        XCTAssertNil(UnreadTitle.count(from: nil))
        XCTAssertNil(UnreadTitle.count(from: "(٣) An"))   // non-ASCII digits
    }
}

final class NotificationIdentifierTests: XCTestCase {

    func testTagReplacesAndIdFallsBack() {
        XCTAssertEqual(WebViewController.notificationIdentifier(id: 7, tag: "thread-1"),
                       "plume-tag-thread-1")
        // Same tag, different instances: one entry, replaced.
        XCTAssertEqual(WebViewController.notificationIdentifier(id: 8, tag: "thread-1"),
                       WebViewController.notificationIdentifier(id: 7, tag: "thread-1"))
        XCTAssertEqual(WebViewController.notificationIdentifier(id: 7, tag: ""), "plume-7")
        XCTAssertEqual(WebViewController.notificationIdentifier(id: 7, tag: nil), "plume-7")
    }
}

final class PopupNotificationIdentifierTests: XCTestCase {

    // A call window numbers its notifications from 1 too; it must never
    // replace or close the main page's notification with the same id.
    func testPopupIdentifiersAreSeparate() {
        XCTAssertNotEqual(WebViewController.notificationIdentifier(id: 1, tag: nil, fromPopup: true),
                          WebViewController.notificationIdentifier(id: 1, tag: nil))
        XCTAssertNotEqual(WebViewController.notificationIdentifier(id: 1, tag: "t", fromPopup: true),
                          WebViewController.notificationIdentifier(id: 1, tag: "t"))
    }
}
