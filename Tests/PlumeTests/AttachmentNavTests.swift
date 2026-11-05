import XCTest
@testable import Plume

final class AttachmentNavTests: XCTestCase {
    private let a = NSObject(), b = NSObject(), reload = NSObject()
    private func id(_ o: NSObject) -> ObjectIdentifier { ObjectIdentifier(o) }

    func testClickedAttachmentIsTaggedUntilItsResponse() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        XCTAssertTrue(t.started(id(a)))          // no loading pill
        XCTAssertTrue(t.responseForMainFrame())  // guard the redirect
        XCTAssertFalse(t.responseForMainFrame()) // consumed
    }

    // Second attachment clicked while the first loads: WebKit decides and
    // starts B, then reports A cancelled. A's failure must not untag B.
    func testSupersededFailureKeepsTheSuccessorTagged() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        _ = t.started(id(a))
        t.decided(isAttachment: true)
        _ = t.started(id(b))
        t.failed(id(a))
        XCTAssertTrue(t.responseForMainFrame())
    }

    func testSupersededFailureBeforeTheSuccessorStarts() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        _ = t.started(id(a))
        t.decided(isAttachment: true)
        t.failed(id(a))
        XCTAssertTrue(t.started(id(b)))
        XCTAssertTrue(t.responseForMainFrame())
    }

    // An ordinary navigation after an attachment is never treated as one:
    // that would cancel a reload of Messenger itself.
    func testOrdinaryNavigationIsNotAnAttachment() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        _ = t.started(id(a))
        t.decided(isAttachment: false)
        XCTAssertFalse(t.started(id(reload)))
        XCTAssertFalse(t.responseForMainFrame())
    }

    // An attachment decision whose navigation never started cannot outlive
    // the next main-frame decision.
    func testStaleExpectationIsOverwritten() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        t.decided(isAttachment: false)
        XCTAssertFalse(t.started(id(reload)))
        XCTAssertFalse(t.responseForMainFrame())
    }

    func testDirectLoadIsTaggedAtOnce() {
        var t = AttachmentNavTracker()
        t.loadedDirectly(id(a))
        t.decided(isAttachment: false)   // WebKit's decision for that load
        XCTAssertTrue(t.started(id(a)))
        XCTAssertTrue(t.responseForMainFrame())
    }

    func testOwnFailureClearsTheTag() {
        var t = AttachmentNavTracker()
        t.decided(isAttachment: true)
        _ = t.started(id(a))
        t.failed(id(a))
        XCTAssertFalse(t.responseForMainFrame())
    }
}
