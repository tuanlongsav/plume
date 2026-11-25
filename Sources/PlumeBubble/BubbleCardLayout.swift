import CoreGraphics
import Foundation

/// Pure sizing and screen-placement geometry for the floating bubble card.
/// Extracted from `ChatBubbleController` so every viewport floor, docked-row
/// lane reservation and screen clamp is shared and unit-testable.
public enum BubbleCardLayout {
    /// Portrait by default — deep enough for roughly fifteen to twenty messages.
    public static let cardSize = CGSize(width: 440, height: 760)
    /// The picker is a list, not a page — it does not inherit the conversation width.
    public static let pickerSize = CGSize(width: 384, height: 620)
    /// Messenger drops the conversation from the DOM below ~900px (Caprine
    /// #1718). The bubble card must be at least this wide so theatre/forward
    /// overlays centre on the same viewport the user sees.
    public static let messengerFloor: CGFloat = 920
    /// Uniform breathing room on all four sides of the card.
    public static let inset: CGFloat = 6

    /// Clamp a card frame origin onto `visible`, reserving the docked-row lane
    /// above the card and snapping to whole points so the card never shimmers.
    public static func clampedOrigin(_ origin: CGPoint,
                                     cardSize size: CGSize,
                                     visible: CGRect,
                                     peakDiameter: CGFloat) -> CGPoint {
        let lane = peakDiameter + 8
        let x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8).rounded()
        let y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - lane).rounded()
        return CGPoint(x: x, y: y)
    }

    /// Position the card below `head`, right-aligned on the right half of the
    /// screen and left-aligned on the left half, then clamped onto `visible`.
    public static func cardOrigin(under head: CGPoint,
                                  cardSize size: CGSize,
                                  visible: CGRect,
                                  canvas: CGFloat,
                                  peakDiameter: CGFloat) -> CGPoint {
        let rawX = head.x > visible.midX
            ? head.x + canvas / 2 - size.width
            : head.x - canvas / 2
        let rawY = head.y - canvas / 2 - 10 - size.height
        return clampedOrigin(CGPoint(x: rawX, y: rawY),
                             cardSize: size, visible: visible, peakDiameter: peakDiameter)
    }

    /// Content size for showing a conversation thread (respecting `messengerFloor`).
    public static func threadContentSize(saved: CGSize?,
                                         minSize: CGSize,
                                         visible: CGRect,
                                         peakDiameter: CGFloat) -> CGSize {
        let base = saved ?? cardSize
        let lane = peakDiameter + 10
        return CGSize(
            width: min(max(base.width, messengerFloor, minSize.width), visible.width - 16),
            height: min(max(base.height, minSize.height), visible.height - lane)
        )
    }

    /// Content size for showing the native conversation picker.
    public static func pickerContentSize(visible: CGRect, canvas: CGFloat) -> CGSize {
        CGSize(
            width: min(pickerSize.width, visible.width - 16),
            height: min(pickerSize.height, visible.height - canvas - 28)
        )
    }

    /// Content size when Messenger's photo theatre expands the card.
    public static func theaterContentSize(minSize: CGSize,
                                          visible: CGRect,
                                          peakDiameter: CGFloat) -> CGSize {
        let lane = peakDiameter + 12
        let pad: CGFloat = 10
        return CGSize(
            width: max(minSize.width, visible.width - pad * 2),
            height: max(minSize.height, visible.height - lane - pad)
        )
    }

    /// Frame origin for the expanded photo-theatre card.
    public static func theaterOrigin(frameSize: CGSize,
                                     visible: CGRect,
                                     peakDiameter: CGFloat) -> CGPoint {
        let lane = peakDiameter + 12
        return CGPoint(
            x: (visible.minX + (visible.width - frameSize.width) / 2).rounded(),
            y: (visible.maxY - lane - frameSize.height).rounded()
        )
    }

    /// Restored content size when exiting photo theatre.
    public static func restoredTheaterSize(saved: CGSize,
                                           minSize: CGSize,
                                           visible: CGRect,
                                           peakDiameter: CGFloat) -> CGSize {
        let lane = peakDiameter + 10
        return CGSize(
            width: min(max(saved.width, minSize.width), visible.width - 16),
            height: min(max(saved.height, minSize.height), visible.height - lane)
        )
    }
}
