import AppKit
import CoreGraphics

/// Pure geometry for parking and moving the bubble chain across displays.
/// Kept free of `NSScreen` so every display-selection and seam-hop rule is
/// unit-tested directly on `CGRect` layouts.
public enum DisplayHop {
    /// Whether to park on the right edge of `to` after leaving `from`.
    /// Side-by-side displays use the shared seam; stacked/fallback keeps the
    /// side `headX` was closer to on `from`.
    public static func preferRightEdge(from: CGRect, to: CGRect, headX: CGFloat,
                                       half: CGFloat, margin: CGFloat) -> Bool {
        let sideBySide = abs(from.midX - to.midX) >= abs(from.midY - to.midY)
        if sideBySide { return from.midX > to.midX }
        let left = from.minX + half + margin
        let right = from.maxX - half - margin
        return abs(headX - right) <= abs(headX - left)
    }

    public static func edgeX(preferRight: Bool, visible: CGRect,
                             half: CGFloat, margin: CGFloat) -> CGFloat {
        preferRight
            ? visible.maxX - half - margin
            : visible.minX + half + margin
    }

    /// Compute the seam edge and proportional Y landing point when hopping
    /// from one display to another — shared by `teleportChain` and `endDrag`.
    public static func hopLanding(from: CGRect,
                                  fromVisible: CGRect,
                                  to: CGRect,
                                  toVisible: CGRect,
                                  head: CGPoint,
                                  half: CGFloat,
                                  margin: CGFloat) -> (preferRight: Bool, point: CGPoint) {
        let preferRight = preferRightEdge(from: from, to: to, headX: head.x,
                                          half: half, margin: margin)
        let x = edgeX(preferRight: preferRight, visible: toVisible,
                      half: half, margin: margin)
        let fy = fromVisible.height > 0 ? (head.y - fromVisible.minY) / fromVisible.height : 0.5
        let y = toVisible.minY + fy * toVisible.height
        return (preferRight, CGPoint(x: x, y: y))
    }

    /// Pick the display frame best covering a `canvas×canvas` square around
    /// `point`, falling back to nearest midpoint when `point` sits in a dead
    /// zone between displays of differing heights.
    public static func nearestFrameIndex(to point: CGPoint,
                                         canvas: CGFloat,
                                         in frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        let rect = CGRect(x: point.x - canvas / 2, y: point.y - canvas / 2,
                          width: canvas, height: canvas)
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (i, frame) in frames.enumerated() {
            let intersection = frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = i
            }
        }
        if let bestIndex { return bestIndex }
        return frames.indices.min {
            hypot(frames[$0].midX - point.x, frames[$0].midY - point.y)
                < hypot(frames[$1].midX - point.x, frames[$1].midY - point.y)
        }
    }

    /// Display just past `frames[currentIndex]` in the direction of flick `velocity`.
    public static func frameIndexBeyond(currentIndex: Int,
                                        velocity v: CGPoint,
                                        in frames: [CGRect]) -> Int? {
        guard frames.indices.contains(currentIndex), hypot(v.x, v.y) >= 100 else { return nil }
        let f = frames[currentIndex]
        var probe = CGPoint(x: f.midX, y: f.midY)
        if abs(v.x) >= abs(v.y) {
            probe.x = v.x < 0 ? f.minX - 40 : f.maxX + 40
        } else {
            probe.y = v.y < 0 ? f.minY - 40 : f.maxY + 40
        }
        return frames.indices.first { $0 != currentIndex && frames[$0].contains(probe) }
    }

    /// Neighbouring display across a shared seam when `head` or `cursor` sits
    /// within `seam` points of `frames[currentIndex]`'s boundary.
    public static func frameIndexAcrossSeam(currentIndex: Int,
                                            head: CGPoint,
                                            cursor: CGPoint,
                                            in frames: [CGRect],
                                            seam: CGFloat = 140) -> Int? {
        guard frames.indices.contains(currentIndex) else { return nil }
        let f = frames[currentIndex]
        let probes: [(Bool, CGPoint)] = [
            (head.x <= f.minX + seam || cursor.x <= f.minX + seam, CGPoint(x: f.minX - 40, y: cursor.y)),
            (head.x >= f.maxX - seam || cursor.x >= f.maxX - seam, CGPoint(x: f.maxX + 40, y: cursor.y)),
            (head.y <= f.minY + seam || cursor.y <= f.minY + seam, CGPoint(x: cursor.x, y: f.minY - 40)),
            (head.y >= f.maxY - seam || cursor.y >= f.maxY - seam, CGPoint(x: cursor.x, y: f.maxY + 40)),
        ]
        for (nearEdge, probe) in probes where nearEdge {
            if let hit = frames.indices.first(where: { $0 != currentIndex && frames[$0].contains(probe) }) {
                return hit
            }
        }
        return nil
    }

    /// True when `point` sits well inside `visibleFrame` (at least `inset`
    /// points from each edge), avoiding jitter on shared seams.
    public static func isInsideInterior(frame: CGRect,
                                        visibleFrame: CGRect,
                                        point: CGPoint,
                                        inset: CGFloat) -> Bool {
        let v = visibleFrame.insetBy(dx: inset, dy: inset)
        if v.width <= 0 || v.height <= 0 { return frame.contains(point) }
        return v.contains(point)
    }

    /// Whether the pointer moved since the previous mouse poll. Kept apart
    /// from the hover position, which the mouse monitors rewrite on every
    /// event: by the next poll that already holds where the pointer came to
    /// rest, so a pointer parked on another display never read as moved and
    /// the chain never followed it.
    public struct PollMotion {
        private var last: CGPoint?

        public init() {}

        /// Records `p` as this poll's sample.
        public mutating func moved(to p: CGPoint) -> Bool {
            defer { last = p }
            guard let last else { return true }
            return hypot(p.x - last.x, p.y - last.y) >= 0.5
        }
    }
}

/// Thin AppKit adapter connecting `DisplayHop`'s pure geometry to `NSScreen.screens`.
final class ScreenResolver {
    private var lastKnownScreen: NSScreen? = NSScreen.main ?? NSScreen.screens.first

    func nearest(to p: NSPoint) -> NSScreen {
        let screens = NSScreen.screens
        let frames = screens.map(\.frame)
        let found = DisplayHop.nearestFrameIndex(to: p, canvas: Chain.canvas, in: frames)
            .map { screens[$0] } ?? NSScreen.main
        if let found { lastKnownScreen = found; return found }
        // While displays reconfigure, `NSScreen.screens` can be briefly empty
        // (a clamshell Mac losing its only monitor); keep the last display until one returns.
        return lastKnownScreen ?? NSScreen()
    }

    func beyond(_ current: NSScreen, velocity v: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let idx = screens.firstIndex(where: { $0 === current }) else { return nil }
        return DisplayHop.frameIndexBeyond(currentIndex: idx, velocity: v, in: screens.map(\.frame))
            .map { screens[$0] }
    }

    func acrossSeam(from head: NSPoint, cursor: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        let current = nearest(to: head)
        guard let idx = screens.firstIndex(where: { $0 === current }) else { return nil }
        return DisplayHop.frameIndexAcrossSeam(
            currentIndex: idx, head: head, cursor: cursor, in: screens.map(\.frame)
        ).map { screens[$0] }
    }

    func isInterior(_ screen: NSScreen, contains p: NSPoint, inset: CGFloat) -> Bool {
        DisplayHop.isInsideInterior(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                    point: p, inset: inset)
    }
}
