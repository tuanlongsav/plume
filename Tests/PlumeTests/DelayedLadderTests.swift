import XCTest
@testable import PlumeCore

final class DelayedLadderTests: XCTestCase {

    func testRunsAllScheduledStepsInOrder() {
        let ladder = DelayedLadder()
        let done = expectation(description: "all rungs fire")
        var hits: [Int] = []

        ladder.schedule(delays: [0.0, 0.02, 0.04]) { gen in
            hits.append(gen)
            if hits.count == 3 { done.fulfill() }
        }

        wait(for: [done], timeout: 1.0)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(Set(hits).count, 1)
    }

    func testCancelStopsRemainingRungsAndBumpsGeneration() {
        let ladder = DelayedLadder()
        let settled = expectation(description: "cancelled ladder stays quiet")
        var count = 0

        ladder.schedule(delays: [0.0, 0.05, 0.10]) { _ in
            count += 1
            if count == 1 { ladder.cancel() }
        }
        let genAtCancel = ladder.generation

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(ladder.generation, genAtCancel)
    }

    func testRescheduleSupersedesEarlierRun() {
        let ladder = DelayedLadder()
        let done = expectation(description: "only second generation fires")
        var generations: [Int] = []

        ladder.schedule(delays: [0.03, 0.06]) { generations.append($0) }
        let firstGen = ladder.generation

        ladder.schedule(delays: [0.02]) { gen in
            generations.append(gen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done.fulfill() }
        }
        let secondGen = ladder.generation

        wait(for: [done], timeout: 1.0)
        XCTAssertNotEqual(firstGen, secondGen)
        XCTAssertEqual(generations, [secondGen])
    }
}
