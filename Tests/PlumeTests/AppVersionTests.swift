import XCTest
@testable import Plume

final class AppVersionTests: XCTestCase {

    func testParsesReleaseTagsAndBundleVersions() {
        XCTAssertEqual(AppVersion("1.2")?.components, [1, 2])
        XCTAssertEqual(AppVersion("v1.2")?.components, [1, 2])
        XCTAssertEqual(AppVersion("V1.2")?.components, [1, 2])
        XCTAssertEqual(AppVersion(" 1.2\n")?.components, [1, 2])
        XCTAssertEqual(AppVersion("0.1.0")?.components, [0, 1, 0])
    }

    func testRejectsAnythingElse() {
        for text in ["", "v", "1", "1.", ".1", "1.2.3.4", "a.b", "1.2-beta", "1..2",
                     "nightly", "1.٢", "1234567.0", "1.100", "1.2.100"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testOrdersNumericallyNotAlphabetically() {
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertLessThan(AppVersion("1.2")!, AppVersion("2.1")!)
        XCTAssertLessThan(AppVersion("0.9")!, AppVersion("1.0")!)
        XCTAssertLessThan(AppVersion("0.1.0")!, AppVersion("1.0")!)
        XCTAssertFalse(AppVersion("1.2")! < AppVersion("1.2")!)
    }

    func testMissingComponentsCompareAsZero() {
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertEqual(Set([AppVersion("1.2")!, AppVersion("v1.2.0")!]).count, 1)
    }

    func testDevBuildsAreAllZero() {
        XCTAssertTrue(AppVersion("0.0.0")!.isDev)
        XCTAssertTrue(AppVersion("0.0")!.isDev)
        XCTAssertFalse(AppVersion("0.1.0")!.isDev)
    }

    // Must match the arithmetic in Scripts/build_app.sh.
    func testBuildNumberMatchesBuildScript() {
        XCTAssertEqual(AppVersion("1.1")!.build, 10100)
        XCTAssertEqual(AppVersion("2.4")!.build, 20400)
        XCTAssertEqual(AppVersion("1.12")!.build, 11200)
        XCTAssertEqual(AppVersion("0.0.0")!.build, 1)
    }

    func testDescriptionAndTag() {
        XCTAssertEqual(AppVersion("v1.2")!.description, "1.2")
        XCTAssertEqual(AppVersion("1.2.0")!.description, "1.2")
        XCTAssertEqual(AppVersion("1.2.3")!.description, "1.2.3")
        XCTAssertEqual(AppVersion("1.2")!.tag, "v1.2")
    }
}
