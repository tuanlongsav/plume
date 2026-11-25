import XCTest
@testable import PlumeBubble

final class BubbleChainStateTests: XCTestCase {

    private func head(_ label: String, id: String?) -> BubbleHead<String> {
        BubbleHead(panel: label, conversationID: id, centre: .zero, hoverTarget: 46, born: 0)
    }

    private func makeStore(_ ids: [String?]) -> BubbleChainStore<String> {
        var store = BubbleChainStore<String>()
        for (i, id) in ids.enumerated() {
            store.insert(head(id ?? "APP", id: id), at: i, adjustTrackedIndices: false)
        }
        return store
    }

    func testInsertAtFrontOfContactsShiftsTrackedIndices() {
        var store = makeStore([nil, "A", "B"])
        store.anchorIndex = 1
        store.lastOpenedIndex = 2
        store.hoverFocus = 1

        store.insert(head("X", id: "X"), at: 1, adjustTrackedIndices: true)

        XCTAssertEqual(store.heads.map(\.panel), ["APP", "X", "A", "B"])
        XCTAssertEqual(store.anchorIndex, 2)
        XCTAssertEqual(store.lastOpenedIndex, 3)
        XCTAssertEqual(store.hoverFocus, 2)
    }

    func testInsertIntoEmptyStoreLeavesInitialIndicesAtZero() {
        var store = BubbleChainStore<String>()
        store.insert(head("APP", id: nil), at: 0, adjustTrackedIndices: true)
        XCTAssertEqual(store.anchorIndex, 0)
        XCTAssertEqual(store.lastOpenedIndex, 0)
        XCTAssertNil(store.hoverFocus)
    }

    func testRemoveDropsPinnedAndAdjustsTrackedIndices() {
        var store = makeStore([nil, "A", "B", "C"])
        store.pinnedIDs = ["A", "B"]
        store.anchorIndex = 2
        store.lastOpenedIndex = 3
        store.hoverFocus = 2

        let removed = store.remove(at: 2)
        XCTAssertEqual(removed?.conversationID, "B")
        XCTAssertEqual(store.heads.map(\.panel), ["APP", "A", "C"])
        XCTAssertEqual(store.pinnedIDs, ["A"])
        XCTAssertEqual(store.anchorIndex, 0)
        XCTAssertEqual(store.lastOpenedIndex, 2)
        XCTAssertNil(store.hoverFocus)
    }

    func testMoveUpwardsRemapsAllTrackedIndices() {
        var store = makeStore([nil, "A", "B", "C"])
        store.anchorIndex = 1       // A
        store.lastOpenedIndex = 3   // C
        store.hoverFocus = 2        // B

        store.move(from: 3, to: 1)

        XCTAssertEqual(store.heads.map(\.panel), ["APP", "C", "A", "B"])
        XCTAssertEqual(store.lastOpenedIndex, 1) // C moved 3 -> 1
        XCTAssertEqual(store.anchorIndex, 2)     // A shifted 1 -> 2
        XCTAssertEqual(store.hoverFocus, 3)      // B shifted 2 -> 3
    }

    func testMoveDownwardsRemapsAllTrackedIndices() {
        var store = makeStore([nil, "A", "B", "C"])
        store.anchorIndex = 1       // A
        store.lastOpenedIndex = 3   // C
        store.hoverFocus = 2        // B

        store.move(from: 1, to: 3)

        XCTAssertEqual(store.heads.map(\.panel), ["APP", "B", "C", "A"])
        XCTAssertEqual(store.anchorIndex, 3)     // A moved 1 -> 3
        XCTAssertEqual(store.hoverFocus, 1)      // B shifted 2 -> 1
        XCTAssertEqual(store.lastOpenedIndex, 2) // C shifted 3 -> 2
    }

    func testRemoveAllCanPreserveOrDropPinnedIDs() {
        var store = makeStore([nil, "A"])
        store.pinnedIDs = ["A"]
        store.removeAll(keepingPinned: true)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.pinnedIDs, ["A"])

        store.removeAll(keepingPinned: false)
        XCTAssertTrue(store.pinnedIDs.isEmpty)
    }
}
