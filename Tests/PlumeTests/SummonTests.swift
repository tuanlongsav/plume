import XCTest
@testable import Plume

final class SummonTests: XCTestCase {

    // Only "Plume is what the user is looking at" puts it away.
    func testHidesOnlyWhenFrontmostWithMainWindowKey() {
        XCTAssertEqual(Summon.action(appActive: true, appHidden: false,
                                     mainWindowVisible: true, mainWindowKey: true), .hide)
    }

    func testShowsInEveryOtherState() {
        let states: [(Bool, Bool, Bool, Bool)] = [
            (false, false, true, true),    // another app is in front
            (true, true, true, true),      // hidden (⌘H) but still "active" for a moment
            (true, false, false, false),   // main window closed (⌘W)
            (true, false, true, false),    // a PDF or call window is key
            (false, true, false, false),   // hidden and closed
        ]
        for (active, hidden, visible, key) in states {
            XCTAssertEqual(Summon.action(appActive: active, appHidden: hidden,
                                         mainWindowVisible: visible, mainWindowKey: key),
                           .show, "\(active) \(hidden) \(visible) \(key)")
        }
    }

    func testStatusTitleMatchesTheDockBadge() {
        XCTAssertEqual(Summon.statusTitle(unread: 0), "")
        XCTAssertEqual(Summon.statusTitle(unread: 3), "3")
        XCTAssertEqual(Summon.statusTitle(unread: 120), "99+")
        XCTAssertEqual(Summon.statusTitle(unread: 3, hidden: true), "")
    }
}
