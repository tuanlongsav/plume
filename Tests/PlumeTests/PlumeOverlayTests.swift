import AppKit
import XCTest
@testable import PlumeUI

final class PlumeOverlayTests: XCTestCase {

    /// Apple marks `.fullScreenPrimary`, `.fullScreenAuxiliary` and
    /// `.canJoinAllApplications` mutually exclusive. Setting both auxiliary
    /// and canJoinAllApplications left bubbles stuck behind fullscreen apps.
    func testCollectionBehaviorDoesNotMixFullscreenFlags() {
        let b = PlumeOverlay.collectionBehavior
        XCTAssertTrue(b.contains(.canJoinAllSpaces))
        XCTAssertTrue(b.contains(.canJoinAllApplications))
        XCTAssertTrue(b.contains(.stationary))
        XCTAssertTrue(b.contains(.ignoresCycle))
        XCTAssertFalse(b.contains(.fullScreenAuxiliary))
        XCTAssertFalse(b.contains(.fullScreenPrimary))
    }
}
