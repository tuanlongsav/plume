import XCTest
@testable import Plume

/// Both the head's own drag and the controller's cross-display drag release
/// through `Chain.flickVelocity`, so one regression covers both.
final class FlickVelocityTests: XCTestCase {

    func testVelocityOverTrailingWindow() {
        let samples: [(p: NSPoint, t: CFTimeInterval)] = [
            (NSPoint(x: 0, y: 0), 1.000),
            (NSPoint(x: 10, y: -5), 1.020),
            (NSPoint(x: 30, y: -15), 1.040),
        ]
        let v = Chain.flickVelocity(samples, now: 1.045)
        XCTAssertEqual(v.x, 750, accuracy: 0.01)
        XCTAssertEqual(v.y, -375, accuracy: 0.01)
    }

    func testStaleOrShortGesturesDoNotFlick() {
        // Released well after the last sample: the pointer had already stopped.
        XCTAssertEqual(Chain.flickVelocity([(.zero, 1.0), (NSPoint(x: 50, y: 0), 1.03)], now: 1.2), .zero)
        // A single sample, or a span below the measurement gate.
        XCTAssertEqual(Chain.flickVelocity([(.zero, 1.0)], now: 1.0), .zero)
        XCTAssertEqual(Chain.flickVelocity([(.zero, 1.0), (NSPoint(x: 5, y: 0), 1.005)], now: 1.006), .zero)
    }
}
