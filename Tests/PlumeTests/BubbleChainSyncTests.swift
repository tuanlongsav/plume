import XCTest
@testable import Plume

final class BubbleChainSyncTests: XCTestCase {

    func testEmptySnapshotNeverRewritesChain() {
        XCTAssertFalse(BubbleChainSync.shouldApplySnapshot(
            count: 0, contactHeads: 5, inboxHidden: false))
        XCTAssertFalse(BubbleChainSync.shouldApplySnapshot(
            count: 0, contactHeads: 5, inboxHidden: true))
    }

    func testShortSnapshotWhileInboxHiddenIsIgnored() {
        XCTAssertFalse(BubbleChainSync.shouldApplySnapshot(
            count: 1, contactHeads: 5, inboxHidden: true))
    }

    func testCompleteSnapshotAppliesEvenWhenInboxHidden() {
        XCTAssertTrue(BubbleChainSync.shouldApplySnapshot(
            count: 5, contactHeads: 5, inboxHidden: true))
        XCTAssertTrue(BubbleChainSync.shouldApplySnapshot(
            count: 6, contactHeads: 5, inboxHidden: true))
    }

    func testInboxVisibleMayShrinkChainToRecents() {
        XCTAssertTrue(BubbleChainSync.shouldApplySnapshot(
            count: 3, contactHeads: 5, inboxHidden: false))
    }

    func testFreshChainCanGrowFromSnapshot() {
        XCTAssertTrue(BubbleChainSync.shouldApplySnapshot(
            count: 4, contactHeads: 0, inboxHidden: false))
    }
}
