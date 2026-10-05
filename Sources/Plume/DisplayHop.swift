import CoreGraphics

/// Pure geometry for parking the bubble chain when hopping between displays.
/// Kept free of AppKit so the edge choice can be unit-tested.
enum DisplayHop {
    /// Whether to park on the right edge of `to` after leaving `from`.
    /// Side-by-side displays use the shared seam; stacked/fallback keeps the
    /// side `headX` was closer to on `from`.
    static func preferRightEdge(from: CGRect, to: CGRect, headX: CGFloat,
                                half: CGFloat, margin: CGFloat) -> Bool {
        let sideBySide = abs(from.midX - to.midX) >= abs(from.midY - to.midY)
        if sideBySide { return from.midX > to.midX }
        let left = from.minX + half + margin
        let right = from.maxX - half - margin
        return abs(headX - right) <= abs(headX - left)
    }

    static func edgeX(preferRight: Bool, visible: CGRect,
                      half: CGFloat, margin: CGFloat) -> CGFloat {
        preferRight
            ? visible.maxX - half - margin
            : visible.minX + half + margin
    }
}
