import AppKit

// MARK: - Panels

/// The expanded chat card. `.titled` + `.fullSizeContentView` rather than
/// `.borderless`: that buys system rounded corners, shadow, resizing and a
/// draggable titlebar strip for free (a WKWebView swallows mouse events, so
/// `isMovableByWindowBackground` does nothing on a borderless window).
final class BubbleCardPanel: NSPanel {
    init(contentRect: NSRect) {
        // .nonactivatingPanel is load-bearing for fullscreen overlays: without
        // it, makeKey / app activation yank Plume's Space forward and the card
        // sinks behind Claude Desktop (etc.) while the bubbles — which already
        // use this mask — stay on top.
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable,
                               .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        PlumeOverlay.apply(to: self)
        becomesKeyOnlyIfNeeded = true       // key for the composer, not on every click
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        title = "Plume"                     // never the contact's name
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // All three hidden: with fullSizeContentView they float over the page
        // and land right on Messenger's own back/call buttons. Esc, clicking
        // away, or tapping the same bubble again collapses the card.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 380, height: 420)
        sharingType = .none                 // keep it out of screen shares
    }
    /// Still accept keyboard for the WKWebView composer; nonactivatingPanel
    /// only prevents activating the Plume app / demoting the fullscreen Space.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The card is placed onto whichever display the chain lives on. AppKit's
    /// default clamp pins a window to the screen it already occupies — which is
    /// exactly what left the card behind when the bubbles jumped displays.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override func cancelOperation(_ sender: Any?) {
        (delegate as? ChatBubbleController)?.collapse()
    }
}

/// One floating bubble. Borderless and circular; holds no web view, so nothing
/// private is rendered while collapsed.
final class BubblePanel: NSPanel {
    init(size: CGFloat) {
        // .nonactivatingPanel: .borderless alone still activates Plume on every
        // mouseDown, yanking focus out of whatever the user was typing in.
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        PlumeOverlay.apply(to: self)
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        title = "Plume"
        isOpaque = false
        backgroundColor = .clear
        // The chip casts its own layer shadow with an explicit path: a window
        // shadow is derived from the backing store's alpha once, so it would
        // keep the resting circle's outline while the circle magnifies.
        hasShadow = false
        sharingType = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The physics is allowed to overshoot past the edge; don't let AppKit hand
    /// back an origin other than the one just computed.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A thin cord from the open bubble down to the chat card — shows which head
/// owns the window. Ignores mouse so it never steals clicks from the chips.
final class BubbleTetherPanel: NSPanel {
    private let tether = TetherView(frame: .zero)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        PlumeOverlay.apply(to: self)
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        contentView = tether
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// `from` = bubble attachment (screen), `to` = card attachment (screen).
    func update(from: NSPoint, to: NSPoint) {
        let pad: CGFloat = 16
        let minX = min(from.x, to.x) - pad
        let minY = min(from.y, to.y) - pad
        let w = max(max(from.x, to.x) - minX + pad, 4)
        let h = max(max(from.y, to.y) - minY + pad, 4)
        let frame = NSRect(x: minX, y: minY, width: w, height: h)
        setFrame(frame, display: false)
        tether.start = NSPoint(x: from.x - minX, y: from.y - minY)
        tether.end = NSPoint(x: to.x - minX, y: to.y - minY)
        tether.needsDisplay = true
        // Don't orderFront every frame — that reshuffles the bubble stack and
        // can leave heads behind the card. Only assert when first shown.
        if !isVisible { orderFrontRegardless() }
    }

    func hide() { orderOut(nil) }
}

final class TetherView: NSView {
    var start: NSPoint = .zero
    var end: NSPoint = .zero

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: start)
        // Soft cord: bow slightly toward the midpoint so it reads as a string,
        // not a rigid ruler.
        let mid = NSPoint(x: (start.x + end.x) / 2,
                          y: (start.y + end.y) / 2)
        let ctrl1 = NSPoint(x: start.x, y: mid.y)
        let ctrl2 = NSPoint(x: end.x, y: mid.y)
        path.curve(to: end, controlPoint1: ctrl1, controlPoint2: ctrl2)
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.stroke()

        let dot: CGFloat = 5
        for p in [start, end] {
            let r = NSRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
            NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: r).fill()
        }
    }
}
