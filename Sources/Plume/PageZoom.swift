import Foundation

/// Page zoom for View ▸ Zoom In / Zoom Out / Actual Size (⌘+ ⌘− ⌘0).
///
/// `WKWebView.pageZoom` rescales the CSS viewport, so Messenger re-lays out
/// as a browser would: text and controls grow, nothing is a blurred bitmap
/// (pinch magnification already covers that). Fixed steps, like Safari's,
/// so ⌘+ then ⌘− lands back exactly where it started.
enum PageZoom {
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let actual = 1.0
    /// Two levels closer than this are the same one: a stored value may have
    /// been written as a float.
    private static let epsilon = 0.001

    /// What a stored or computed value may be: within the ladder, never NaN.
    static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return actual }
        return min(max(zoom, levels[0]), levels[levels.count - 1])
    }

    static func zoomedIn(from zoom: Double) -> Double {
        levels.first { $0 > zoom + epsilon } ?? levels[levels.count - 1]
    }

    static func zoomedOut(from zoom: Double) -> Double {
        levels.last { $0 < zoom - epsilon } ?? levels[0]
    }

    static func canZoomIn(_ zoom: Double) -> Bool { zoom < levels[levels.count - 1] - epsilon }
    static func canZoomOut(_ zoom: Double) -> Bool { zoom > levels[0] + epsilon }
    static func isActual(_ zoom: Double) -> Bool { abs(zoom - actual) < epsilon }
}
