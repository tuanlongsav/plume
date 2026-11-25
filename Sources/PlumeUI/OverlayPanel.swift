import AppKit

/// Base floating overlay panel shared by the chat card, chat heads, tether and
/// context-menu anchor so overlay flags and frame constraints stay identical.
open class OverlayPanel: NSPanel {
    public init(contentRect: NSRect, styleMask: NSWindow.StyleMask) {
        super.init(contentRect: contentRect,
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        PlumeOverlay.apply(to: self)
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        sharingType = .none                 // keep out of screen shares
    }

    /// Configure a transparent, shadowless borderless surface (bubbles, tether,
    /// context-menu anchor).
    public func configureTransparentSurface() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    open override var canBecomeKey: Bool { false }
    open override var canBecomeMain: Bool { false }

    /// Placed onto whichever display the chain lives on (and allowed to
    /// overshoot during spring motion). AppKit's default clamp pins panels to
    /// their previous screen, which stranded them on display hops.
    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Tiny invisible anchor panel for popping context menus at overlay tier.
    public static func makeMenuAnchor() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.borderless, .nonactivatingPanel]
        )
        panel.configureTransparentSurface()
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        return panel
    }
}
