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

    private func merge(_ current: String, _ recents: String,
                       pinned: String = "", limit: Int) -> String {
        BubbleChainSync.merge(current: current.map(String.init),
                              recents: recents.map(String.init),
                              pinned: Set(pinned.map(String.init)),
                              limit: limit).joined()
    }

    // Without picker heads the chain is exactly the newest `limit` recents.
    func testMergeWithoutPinnedFollowsRecents() {
        XCTAssertEqual(merge("ABC", "DABCE", limit: 3), "DAB")
        XCTAssertEqual(merge("", "AAB", limit: 2), "AB")
    }

    // Regression: a head spawned from the picker for an older thread vanished
    // on the next title change, while its card was still open.
    func testPinnedHeadSurvivesOutsideRecentWindow() {
        XCTAssertEqual(merge("XAB", "ABCD", pinned: "X", limit: 4), "XABC")
        XCTAssertEqual(merge("AXB", "ABC", pinned: "X", limit: 5), "AXBC")
    }

    func testPinnedHeadInRecentsTakesItsRank() {
        XCTAssertEqual(merge("XAB", "AXB", pinned: "X", limit: 5), "AXB")
    }

    func testLimitEvictsRecentsBeforePinnedHeads() {
        XCTAssertEqual(merge("XYA", "ABC", pinned: "XY", limit: 3), "XYA")
        XCTAssertEqual(merge("XYZ", "A", pinned: "XYZ", limit: 2), "XY")
    }

    func testPinnedIdWithoutAHeadIsIgnored() {
        XCTAssertEqual(merge("A", "AB", pinned: "Q", limit: 5), "AB")
    }
}
