import AppKit

/// One chat head: a contact's avatar (initials until it loads), or the app
/// itself. Each lives in its own window so it can be dragged on its own, and it
/// carries its conversation directly — there is no hit-testing to get wrong, so
/// a bubble can never open somebody else's chat.
///
/// The whole layer tree is laid out ONCE at `Chain.peak` and afterwards only
/// ever transformed. Magnification therefore costs one `CATransform3D` per
/// bubble per frame — no text layout, no bitmap resample, no shadow rebuild.
final class BubbleChipView: NSView {
    /// nil ⇒ the app chip, which opens the conversation list.
    let conversation: BubbleConversation?
    var onClick: ((BubbleConversation?) -> Void)?
    /// Drag gestures are reported raw; the controller owns the chain physics.
    var onDragBegan: ((NSPoint) -> Void)?          // grab point, screen coords
    var onDragTo: ((NSPoint) -> Void)?             // cursor, screen coords
    var onDragEnded: ((NSPoint) -> Void)?          // flick velocity, pt/s
    /// App chip only: a second click leaves bubble mode, and the secondary
    /// button opens the menu that used to be a button glued over the card.
    var onDoubleClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?

    /// Two views, because a masked layer clips its own shadow: `shadowHost`
    /// casts, `circle` clips. The window's own shadow stays off — it is baked
    /// from the backing store's alpha at order-in, so it would keep the resting
    /// outline while the circle magnifies.
    private let shadowHost = NSView()
    private let circle = NSView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var appliedScale: CGFloat = -1
    private var pressed = false { didSet { if pressed != oldValue { apply() } } }
    private var diameter: CGFloat = Chain.base

    init(conversation: BubbleConversation?) {
        self.conversation = conversation
        super.init(frame: NSRect(x: 0, y: 0, width: Chain.canvas, height: Chain.canvas))
        wantsLayer = true
        toolTip = conversation?.name ?? "Plume"
        let d = Chain.peak

        shadowHost.wantsLayer = true
        shadowHost.frame = NSRect(x: 0, y: 0, width: d, height: d)
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.3
        // Constant radius: an explicit shadowPath skips the alpha analysis, not
        // the blur, so animating the radius would re-render six shadows a frame.
        shadowHost.layer?.shadowRadius = 5
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.layer?.shadowPath = CGPath(ellipseIn: shadowHost.bounds, transform: nil)
        addSubview(shadowHost)

        circle.wantsLayer = true
        circle.frame = shadowHost.bounds
        circle.layer?.masksToBounds = true
        circle.layer?.cornerRadius = d / 2
        circle.layer?.borderWidth = 2
        shadowHost.addSubview(circle)

        imageView.imageScaling = .scaleAxesIndependently   // fill, so the clip is a true circle
        imageView.frame = circle.bounds
        imageView.isHidden = true
        circle.addSubview(imageView)

        if let conversation {
            initialsLabel.stringValue = conversation.initials
            initialsLabel.font = .systemFont(ofSize: d * 0.34, weight: .semibold)
            initialsLabel.alignment = .center
            initialsLabel.textColor = .white
            initialsLabel.sizeToFit()
            initialsLabel.setFrameOrigin(NSPoint(x: (d - initialsLabel.frame.width) / 2,
                                                 y: (d - initialsLabel.frame.height) / 2))
            circle.addSubview(initialsLabel)
        } else {
            let f = FeatherView(variant: .mono, monoColor: .white)
            let w = d * 0.40, h = d * 0.44
            f.frame = NSRect(x: (d - w) / 2, y: (d - h) / 2, width: w, height: h)
            circle.addSubview(f)
        }

        // On shadowHost, not inside `circle`: the circle masks to its bounds, so
        // a badge parked at the square's corner would be drawn as a crescent.
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.borderWidth = 2
        badge.isHidden = true
        shadowHost.addSubview(badge)

        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badge.addSubview(badgeLabel)
        setBadge(conversation?.unread == true ? "" : nil)

        refreshColors()
        apply()
        loadAvatar(conversation?.avatar)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// nil hides the badge, "" shows a plain dot, anything else shows the text.
    /// Laid out at `peak` like the rest of the tree, so the frame transform
    /// scales it along with the head — this is never called per frame.
    func setBadge(_ text: String?) {
        guard let text else { badge.isHidden = true; return }
        badge.isHidden = false
        let d = Chain.peak
        // A count has to be readable at a glance from the corner of the head,
        // so a numeric badge is a third of it. A bare dot stays small.
        let h = text.isEmpty ? d * 0.22 : d * 0.34
        badgeLabel.stringValue = text
        badgeLabel.isHidden = text.isEmpty
        badgeLabel.font = .systemFont(ofSize: h * 0.72, weight: .bold)
        badgeLabel.sizeToFit()
        let w = text.isEmpty ? h : max(h, badgeLabel.frame.width + h * 0.5)
        // Anchored by its trailing edge so a wider badge grows inwards and
        // cannot slide off the canvas.
        let right = d / 2 + d * 0.354 + h / 2
        badge.frame = NSRect(x: right - w, y: d / 2 + d * 0.354 - h / 2, width: w, height: h)
        badge.layer?.cornerRadius = h / 2
        badgeLabel.frame = NSRect(x: 0, y: (h - badgeLabel.frame.height) / 2,
                                  width: w, height: badgeLabel.frame.height)
    }

    /// Called every frame by the controller's loop. Cheap by construction.
    func setDiameter(_ d: CGFloat) {
        guard d != diameter else { return }
        diameter = d
        apply()
    }

    private func apply() {
        let s = max(0, diameter) / Chain.peak * (pressed ? Chain.pressScale : 1)
        guard abs(s - appliedScale) > 0.001 else { return }
        appliedScale = s
        // Layer-backed NSViews keep anchorPoint (0,0), so scale explicitly about
        // the layer's own centre. Actions off: this is our animation, not CA's.
        let c = Chain.peak / 2
        var t = CATransform3DMakeTranslation(c, c, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -c, -c, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowHost.layer?.transform = t
        CATransaction.commit()
    }

    private func refreshColors() {
        withEffectiveAppearance {
            circle.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            circle.layer?.backgroundColor = (conversation == nil
                ? Theme.accent
                : NSColor.controlAccentColor.blended(withFraction: 0.45, of: .black)
                    ?? .systemBlue).cgColor
            badge.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Best effort: the chip already works with initials, so a slow or failed
    /// avatar fetch costs nothing.
    private func loadAvatar(_ url: URL?) {
        guard let url else { return }
        AvatarCache.load(url) { [weak self] image in
            guard let self else { return }
            // A copy, because the cache is shared with the picker's 56pt rows
            // and `size` is a property of the image, not of the view.
            let sized = image.copy() as? NSImage ?? image
            sized.size = NSSize(width: Chain.peak, height: Chain.peak)
            self.imageView.image = sized
            self.imageView.isHidden = false
            self.initialsLabel.isHidden = true
        }
    }

    // MARK: Click vs drag

    // A non-key window withholds mouseDown unless the hit view opts in.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Circular hit against the *visible* head. Panels are `peak`-sized and
    /// can overlap when `step < canvas`; a square hit would let the upper
    /// window's empty corners swallow clicks meant for the neighbour below.
    /// Returning nil here lets the event fall through to the next bubble window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let c = Chain.peak / 2
        let r = max(diameter, Chain.base) / 2
        return hypot(local.x - c, local.y - c) <= r ? self : nil
    }

    private var downAt: NSPoint = .zero
    private var samples: [(p: NSPoint, t: CFTimeInterval)] = []
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        // Control-click is a secondary click on macOS (trackpad / older mice).
        if event.modifierFlags.contains(.control), onSecondaryClick != nil {
            onSecondaryClick?()
            return
        }
        downAt = NSEvent.mouseLocation
        samples = [(downAt, CACurrentMediaTime())]
        didDrag = false
        pressed = true
        // Deliberately NOT onDragBegan: a plain click must never enter the drag
        // state machine, or `dragging` latches on with no mouseUp to clear it.
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if !didDrag,
           abs(now.x - downAt.x) > Chain.dragSlop || abs(now.y - downAt.y) > Chain.dragSlop {
            didDrag = true
            onDragBegan?(downAt)                    // exactly once, past the slop
        }
        samples.append((now, CACurrentMediaTime()))
        if samples.count > Chain.velSamples { samples.removeFirst() }
        if didDrag { onDragTo?(now) }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if didDrag { onDragEnded?(Chain.flickVelocity(samples)); return }
        if event.clickCount >= 2, onDoubleClick != nil { onDoubleClick?() }
        else { onClick?(conversation) }
    }

    /// Global mouse-up across a display boundary never reaches this view —
    /// the controller ends the drag and clears the press highlight from outside.
    func cancelPress() { pressed = false }

    override func rightMouseDown(with event: NSEvent) {
        guard onSecondaryClick != nil else { super.rightMouseDown(with: event); return }
        // Monitors own the menu now (they can lift it above `.screenSaver`
        // bubbles). Ignore the view path so we don't double-present.
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }   // we drive it ourselves
}
