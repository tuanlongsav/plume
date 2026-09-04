import AppKit
import QuartzCore
import WebKit

// TEMPORARY: diagnosing the multi-display card placement. Remove once fixed.
enum PlumeTrace {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("plume-trace.log")
    static func log(_ line: String) {
        guard let d = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
    }
    static func r(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
    static func p(_ p: NSPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}

extension Notification.Name {
    /// Posted by the main web view whenever the dock badge changes.
    static let plumeUnreadChanged = Notification.Name("plume.unreadChanged")
}

// MARK: - Avatar cache

/// Decoded avatars, keyed by URL. Bounded, and main-thread only.
enum AvatarCache {
    private static var images: [URL: NSImage] = [:]
    private static var order: [URL] = []
    private static let limit = 96

    static func image(for url: URL) -> NSImage? { images[url] }

    static func store(_ image: NSImage, for url: URL) {
        if images[url] == nil {
            order.append(url)
            while order.count > limit { images.removeValue(forKey: order.removeFirst()) }
        }
        images[url] = image
    }

    /// Fetch once, then serve from memory. `done` always runs on the main thread.
    static func load(_ url: URL, done: @escaping (NSImage) -> Void) {
        if let cached = image(for: url) { done(cached); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                store(image, for: url)
                done(image)
            }
        }.resume()
    }
}

// MARK: - Model

/// One conversation the bubbles can represent. Built from an on-demand snapshot
/// of Messenger's list — deliberately no message text, only what a bubble needs.
struct BubbleConversation {
    let url: URL
    let name: String
    let avatar: URL?
    let unread: Bool
    let preview: String
    let time: String

    /// Shown until (or instead of) the avatar image loads.
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Hand-written, because Swift's synthesised `Decodable` ignores stored
    /// property defaults: a single absent key threw, `fetchConversations`
    /// swallowed the error and returned nothing, and the whole bubble feature
    /// went quiet. Every field a future Messenger change might drop is optional
    /// here.
    struct Raw: Decodable {
        let href: String
        let name: String
        let avatar: String
        let unread: Bool
        let preview: String
        let time: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decode(String.self, forKey: .href)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) as? String ?? ""
            avatar = (try? c.decodeIfPresent(String.self, forKey: .avatar)) as? String ?? ""
            unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) as? Bool ?? false
            preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) as? String ?? ""
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) as? String ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case href, name, avatar, unread, preview, time
        }
    }

    init?(raw: Raw) {
        guard let thread = ThreadURL.canonical(from: URL(string: raw.href)) else { return nil }
        url = thread
        name = raw.name.isEmpty ? "Messenger" : raw.name
        avatar = raw.avatar.isEmpty ? nil : URL(string: raw.avatar)
        unread = raw.unread
        preview = raw.preview
        time = raw.time
    }
}

// MARK: - Panels

/// The expanded chat card. `.titled` + `.fullSizeContentView` rather than
/// `.borderless`: that buys system rounded corners, shadow, resizing and a
/// draggable titlebar strip for free (a WKWebView swallows mouse events, so
/// `isMovableByWindowBackground` does nothing on a borderless window).
final class BubbleCardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false           // NSPanel defaults to true
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        minSize = NSSize(width: 380, height: 420)
        sharingType = .none                 // keep it out of screen shares
    }
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
        hidesOnDeactivate = false
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
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

// MARK: - Bubble content

/// Tuning for the bubble chain. Geometry first, then the springs.
enum Chain {
    // canvas == peak is load-bearing: the panel never resizes, so a magnified
    // circle can never be clipped, and magnification never moves a bubble —
    // which is what lets hover be measured against live positions without the
    // scale → layout → distance → scale feedback loop the real Dock must fight.
    /// Resting circle — the one number the user sets.
    static var base: CGFloat { Preferences.bubbleSize }
    /// Circle under the cursor. 26% is enough to read as Dock magnification
    /// without the head swallowing its neighbours.
    static var peak: CGFloat { (base * 1.26).rounded() }
    /// Panel edge. Equal to `peak` for the life of a panel.
    static var canvas: CGFloat { peak }
    /// Centre-to-centre, and therefore the gap: derived from the canvas, so
    /// resizing the heads never leaves them crammed together or adrift.
    ///
    /// Deliberately == canvas: overlapping panels would need
    /// `ignoresMouseEvents` toggled from cursor position to let clicks through
    /// their dead corners, and a bubble you cannot click is a far worse bug
    /// than a slightly airier chain. Non-overlapping panels make "a bubble
    /// never opens someone else's chat" a property of the geometry.
    static var step: CGFloat { canvas }
    static let margin: CGFloat = 6         // gap to visibleFrame at rest

    /// Anchor spring — the released bubble flying to the edge.
    static let anchorOmega: CGFloat = 13
    static let anchorZeta: CGFloat = 0.9
    static let maxOvershoot: CGFloat = 10  // pt past the rest line, hard clamp

    /// Followers. τ is the lag behind the bubble in front; ω = 2ζ/τ. Ramping τ
    /// down the chain makes it unfurl instead of sliding rigidly.
    static let trailZeta: CGFloat = 0.8
    static func trailTau(_ k: Int) -> CGFloat { 0.050 + 0.008 * CGFloat(min(k, 5) - 1) }
    static var maxLink: CGFloat { step * 1.6 }   // rope cap on the spread

    static let dtMin: CGFloat = 1.0 / 240
    static let dtMax: CGFloat = 1.0 / 30   // ω·dt ≤ 1.07 at the stiffest link

    /// Flick measurement. A mouse polls at 125Hz and a trackpad at ~90, so the
    /// span gate has to be reachable within a handful of samples.
    static let velWindow: CFTimeInterval = 0.060
    static let velMinSpan: CFTimeInterval = 0.015
    static let velSamples = 6
    static let velStaleGate: CFTimeInterval = 0.060
    static let flickFloor: CGFloat = 320   // below this the position picks the edge
    static let maxFlick: CGFloat = 2600
    static let projectTauX: CGFloat = 0.12
    static let projectTauY: CGFloat = 0.06
    static let dragSlop: CGFloat = 3

    /// Dock magnification: raised cosine, so there is no kink at the rim.
    static var magRadius: CGFloat { step * 2.6 }
    static let magRate: CGFloat = 22
    static let magEpsilon: CGFloat = 0.05
    static let pressScale: CGFloat = 0.93

    static let restDistance: CGFloat = 0.3
    static let restSpeed: CGFloat = 1.5

    /// Exact closed-form step of a damped spring toward `target` over `dt`.
    /// Identical motion at 60 and 120Hz; cannot blow up on a stalled frame.
    @inline(__always)
    static func spring(_ x: inout CGFloat, _ v: inout CGFloat,
                       to target: CGFloat, omega w: CGFloat,
                       zeta z: CGFloat, dt: CGFloat) {
        let d = x - target
        if z < 0.999 {                                  // underdamped
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * dt)
            let c = cos(wd * dt), s = sin(wd * dt)
            let a = d, b = (v + z * w * d) / wd
            x = target + e * (a * c + b * s)
            v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s)
        } else if z < 1.001 {                           // critically damped
            let e = exp(-w * dt)
            let a = d, b = v + w * d
            x = target + e * (a + b * dt)
            v = e * (b - w * (a + b * dt))
        } else {                                        // overdamped
            let r = w * (z * z - 1).squareRoot()
            let r1 = -z * w + r, r2 = -z * w - r
            let c2 = (v - r1 * d) / (r2 - r1)
            let c1 = d - c2
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = target + c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
    }

    @inline(__always)
    static func clamp(_ x: inout CGFloat, _ v: inout CGFloat, _ lo: CGFloat, _ hi: CGFloat) {
        guard lo <= hi else { x = min(max(x, hi), lo); v = 0; return }
        if x < lo { x = lo; if v < 0 { v = 0 } }
        else if x > hi { x = hi; if v > 0 { v = 0 } }
    }
}

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
    var onSecondaryClick: ((NSPoint) -> Void)?

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

    /// The whole canvas is live. `step == canvas`, so panels never overlap and
    /// a forgiving square target cannot steal a neighbour's click — while a
    /// circular test would leave dead corners that swallow clicks outright,
    /// since a nil hitTest does not fall through to the window below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    private var downAt: NSPoint = .zero
    private var samples: [(p: NSPoint, t: CFTimeInterval)] = []
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
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
        if didDrag { onDragEnded?(flickVelocity()); return }
        if event.clickCount >= 2, onDoubleClick != nil { onDoubleClick?() }
        else { onClick?(conversation) }
    }

    /// Global mouse-up across a display boundary never reaches this view —
    /// the controller ends the drag and clears the press highlight from outside.
    func cancelPress() { pressed = false }

    override func rightMouseDown(with event: NSEvent) {
        guard onSecondaryClick != nil else { super.rightMouseDown(with: event); return }
        onSecondaryClick?(convert(event.locationInWindow, from: nil))
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }   // we drive it ourselves

    /// Regression over a trailing time window. An EMA with a fixed coefficient
    /// over uneven dt would make flick strength depend on whether the user is
    /// on a 125Hz mouse or a 90Hz trackpad.
    private func flickVelocity() -> NSPoint {
        let now = CACurrentMediaTime()
        guard let last = samples.last, now - last.t <= Chain.velStaleGate else { return .zero }
        let window = samples.filter { last.t - $0.t <= Chain.velWindow }
        guard let first = window.first, window.count >= 2 else { return .zero }
        let span = last.t - first.t
        guard span >= Chain.velMinSpan else { return .zero }
        return NSPoint(x: (last.p.x - first.p.x) / CGFloat(span),
                       y: (last.p.y - first.p.y) / CGFloat(span))
    }
}

/// One row of the app chip's list, built to the same metrics Messenger uses in
/// its own sidebar: a 56pt avatar, a 72pt row, and the timestamp inline after
/// the preview rather than in a column of its own.
final class ConversationRow: NSView {
    let conversation: BubbleConversation
    var onPick: ((BubbleConversation) -> Void)?
    private let avatarView = NSImageView()
    private let initialsLabel = NSTextField(labelWithString: "")

    init(conversation: BubbleConversation) {
        self.conversation = conversation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 28
        avatarView.layer?.masksToBounds = true
        avatarView.imageScaling = .scaleAxesIndependently
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatarView)

        initialsLabel.stringValue = conversation.initials
        initialsLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        initialsLabel.alignment = .center
        initialsLabel.textColor = .secondaryLabelColor
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)

        let name = NSTextField(labelWithString: conversation.name)
        name.font = .systemFont(ofSize: 15, weight: conversation.unread ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        // One line, the way Messenger writes it: "Bạn: Ko, up fw bản mới… · 1 giờ".
        var second = conversation.preview
        if !conversation.time.isEmpty {
            second = second.isEmpty ? conversation.time : "\(second) · \(conversation.time)"
        }
        let detail = NSTextField(labelWithString: second)
        detail.font = .systemFont(ofSize: 13, weight: conversation.unread ? .medium : .regular)
        detail.textColor = conversation.unread ? .labelColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.isHidden = !conversation.unread
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),
            initialsLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -10),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        loadAvatar()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func loadAvatar() {
        guard let url = conversation.avatar else { return }
        AvatarCache.load(url) { [weak self] image in
            guard let self else { return }
            self.avatarView.image = image
            self.initialsLabel.isHidden = true
        }
    }

    override func mouseUp(with event: NSEvent) { onPick?(conversation) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tracker: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        // .inVisibleRect: AppKit keeps the tracking rect in step with the row's
        // real frame. A fixed `bounds` rect is captured before Auto Layout has
        // placed the row and never follows it as the list scrolls, which is how
        // a row lights up under a cursor that is nowhere near it.
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracker = t
    }
    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    /// Trust the pointer, not just the event: rows are rebuilt whenever the
    /// filter changes, and a freshly built row can inherit an enter it never
    /// earned.
    func syncHighlight() {
        guard let window else { setHighlighted(false); return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHighlighted(bounds.contains(p))
    }

    private func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : nil
    }
}

/// Top-down coordinates. An NSScrollView's document view is bottom-up by
/// default, which stacks rows from the bottom and opens the list at its end.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The app chip's picker: Messenger's own sidebar, rebuilt natively.
///
/// Native rather than borrowed, because navigating the card to messenger.com
/// immediately redirects into the most recent conversation — the list never
/// actually appears. Laid out to match the real thing: a heading, a search
/// field, then 72pt rows.
final class ConversationListView: NSView {
    var onPick: ((BubbleConversation) -> Void)?
    private let stack = NSStackView()
    private let search = NSSearchField()
    private weak var scroll: NSScrollView?
    private var all: [BubbleConversation] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let title = NSTextField(labelWithString: L.t("Đoạn chat", "Chats"))
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        search.placeholderString = L.t("Tìm kiếm trên Messenger", "Search Messenger")
        search.font = .systemFont(ofSize: 13)
        search.focusRingType = .none
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scroll = scroll
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        scroll.documentView = clip
        addSubview(scroll)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            search.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ conversations: [BubbleConversation]) {
        all = conversations
        render()
    }

    @objc private func filterChanged() { render() }

    private func render() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for convo in shown {
            let row = ConversationRow(conversation: convo)
            row.onPick = { [weak self] c in self?.onPick?(c) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Settle scroll position and highlight once the rows have frames.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scroll?.documentView?.scroll(.zero)
            self.scroll?.reflectScrolledClipView(self.scroll!.contentView)
            self.stack.arrangedSubviews
                .compactMap { $0 as? ConversationRow }
                .forEach { $0.syncHighlight() }
        }
    }
}

// MARK: - Controller

/// Android-style chat heads: one bubble per conversation, each showing that
/// contact's avatar, all sharing a single card and a single web view so the
/// memory cost stays flat no matter how many bubbles are on screen.
final class ChatBubbleController: NSObject, NSWindowDelegate {

    static private(set) var shared: ChatBubbleController?
    static var isOpen: Bool { shared != nil }

    /// Called when the user asks to leave bubble mode.
    var onExitBubbleMode: (() -> Void)?

    /// Enter bubble mode with a snapshot of the user's conversations.
    @discardableResult
    static func show(conversations: [BubbleConversation],
                     webView: WKWebView,
                     onExit: @escaping () -> Void) -> ChatBubbleController {
        if let existing = shared { return existing }
        let c = ChatBubbleController()
        shared = c
        c.onExitBubbleMode = onExit
        c.adopt(webView)
        c.build(conversations)
        return c
    }

    static func hide() {
        shared?.dismiss()
        shared = nil
    }

    private static let gap: CGFloat = 8
    /// Portrait by default — a conversation is a column of messages, and this
    /// is deep enough for roughly fifteen to twenty of them at once.
    private static let cardSize = NSSize(width: 440, height: 760)
    /// The picker is a list, not a page — it should not inherit the width the
    /// user chose for reading a conversation.
    private static let pickerSize = NSSize(width: 384, height: 620)
    private static let titleStrip: CGFloat = 22
    // Bumped: the previous key holds sizes produced by an auto-widen that has
    // since been removed, and those are not sizes anyone chose.
    private static let sizeKey = "plume.bubbleCardSize2"
    private static let originKey = "plume.bubbleOrigin"

    private let card: BubbleCardPanel
    private var bubbles: [BubblePanel] = []
    private var webView: WKWebView!
    private var isExpanded = false
    private var currentThread: URL?
    private var showingPicker = false
    /// Index of the bubble the card belongs to, for the fold-away animation.
    private var lastOpenedIndex = 0
    private var collapseWork: DispatchWorkItem?
    private let listView = ConversationListView(frame: .zero)
    /// Supplied by the owner: the main web view still holds the live list.
    var fetchConversations: ((Int, @escaping ([BubbleConversation]) -> Void) -> Void)?
    /// Uniform breathing room on all four sides of the card.
    private static let inset: CGFloat = 6

    private override init() {
        card = BubbleCardPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize))
        super.init()
        card.delegate = self
        restoreCardSize()
    }

    // MARK: Build

    private func build(_ conversations: [BubbleConversation]) {
        // App chip heads the chain, then contacts newest → oldest (the order
        // Messenger's own list is already in), capped by the user's setting.
        let capped = Array(conversations.prefix(Preferences.bubbleLimit))
        let entries: [BubbleConversation?] = [nil] + capped.map { $0 }
        let head = savedHeadCentre()
        for (i, convo) in entries.enumerated() {
            appendBubble(convo, centre: NSPoint(x: head.x, y: head.y - CGFloat(i) * Chain.step))
        }
        anchorIndex = 0
        anchorTarget = clampedAnchor(head)
        installMouseMonitors()
        startMousePoll()
        // The main web view keeps deriving the unread count from the page title
        // even with its window hidden, so that is the signal for the badges.
        NotificationCenter.default.addObserver(
            self, selector: #selector(unreadChanged(_:)),
            name: .plumeUnreadChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wake()
    }

    /// Add one head. `centre` is where it starts; the loop takes it from there.
    private func appendBubble(_ convo: BubbleConversation?, centre: NSPoint, at index: Int? = nil) {
        let chip = BubbleChipView(conversation: convo)
        chip.setDiameter(0)          // the pop-in starts from nothing
        let panel = BubblePanel(size: Chain.canvas)
        panel.contentView = chip

        // Weak on `panel` and `chip` as well as `self`: the panel owns the chip
        // as its contentView, so a strong capture here closes the loop and every
        // head ever created stays alive for the life of the process.
        chip.onClick = { [weak self, weak panel] c in
            guard let self, let panel else { return }
            self.lastOpenedIndex = self.index(of: panel) ?? 0
            self.open(c)
        }
        chip.onDragBegan = { [weak self, weak panel] grab in
            guard let panel else { return }
            self?.beginDrag(panel, grab: grab)
        }
        chip.onDragTo = { [weak self] cursor in self?.dragTo(cursor) }
        chip.onDragEnded = { [weak self] v in self?.endDrag(velocity: v) }
        if convo == nil {   // the app chip carries the app-level gestures
            chip.onDoubleClick = { [weak self] in self?.onExitBubbleMode?() }
            chip.onSecondaryClick = { [weak self, weak chip] p in
                guard let chip else { return }
                self?.showChipMenu(from: chip, at: p)
            }
        }

        let i = index.map { min($0, bubbles.count) } ?? bubbles.count
        bubbles.insert(panel, at: i)
        centres.insert(centre, at: i)
        velocities.insert(.zero, at: i)
        // New heads pop in rather than appearing at full size.
        diameters.insert(0, at: i)
        hoverTargets.insert(Chain.base, at: i)
        born.insert(CACurrentMediaTime() + Double(i) * 0.045, at: i)

        panel.setFrameOrigin(NSPoint(x: centre.x - Chain.canvas / 2,
                                     y: centre.y - Chain.canvas / 2))
        panel.orderFront(nil)
    }

    /// Manual KVO needs manual teardown — an observed object deallocating with
    /// observers still attached traps.
    deinit { release() }

    /// Ordering a panel out releases nothing (`isReleasedWhenClosed` is false),
    /// so retire it explicitly.
    private func retire(_ panel: BubblePanel) {
        if let chip = chip(panel) {
            chip.onClick = nil
            chip.onDragBegan = nil
            chip.onDragTo = nil
            chip.onDragEnded = nil
            chip.onDoubleClick = nil
            chip.onSecondaryClick = nil
        }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func chip(_ panel: BubblePanel) -> BubbleChipView? {
        panel.contentView as? BubbleChipView
    }

    /// A display was added, removed or rearranged. The chain can be sitting in
    /// coordinates no screen covers any more, with the loop parked and nothing
    /// to restart it — so pull it back and wake up.
    @objc private func screensChanged() {
        guard !bubbles.isEmpty else { return }
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        if card.isVisible { keepCardOnScreen() }
        wake()
    }

    /// Last total seen, so a rebuilt app chip does not lose its badge until
    /// Messenger happens to change the page title again.
    private var unreadTotal = 0

    private func applyTotalBadge() {
        bubbles.first.flatMap(chip)?
            .setBadge(unreadTotal > 0 ? (unreadTotal > 99 ? "99+" : String(unreadTotal)) : nil)
    }

    @objc private func unreadChanged(_ note: Notification) {
        unreadTotal = (note.userInfo?["count"] as? Int) ?? 0
        applyTotalBadge()
        // The title changes in bursts while a conversation updates; one snapshot
        // after the burst is worth the same as ten during it.
        unreadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshUnreadFlags() }
        unreadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private var unreadWork: DispatchWorkItem?

    /// Which contacts are unread comes from a fresh snapshot, not from the one
    /// the bubbles were built with — that one is a photograph of the past.
    private func refreshUnreadFlags() {
        fetchConversations?(max(Preferences.bubbleLimit * 3, 12)) { [weak self] convos in
            guard let self else { return }
            let unread = Set(convos.filter(\.unread).map(\.url))
            for panel in self.bubbles {
                guard let chip = self.chip(panel), let convo = chip.conversation else { continue }
                chip.setBadge(unread.contains(convo.url) ? "" : nil)
            }
        }
    }

    private func conversation(of panel: BubblePanel) -> BubbleConversation? {
        (panel.contentView as? BubbleChipView)?.conversation
    }

    /// Picking from the app chip's list earns that contact its own head, the way
    /// tapping a chat on Android spawns a bubble. The oldest contact head falls
    /// off once the chain hits the user's limit.
    private func spawnBubble(for convo: BubbleConversation) {
        guard !bubbles.contains(where: { conversation(of: $0)?.url == convo.url }) else { return }
        // index 0 is the app chip; contacts follow it.
        if bubbles.count - 1 >= Preferences.bubbleLimit, bubbles.count > 1 {
            removeBubble(at: bubbles.count - 1)
        }
        let centre = centres.first.map { NSPoint(x: $0.x, y: $0.y - Chain.step) } ?? savedHeadCentre()
        appendBubble(convo, centre: centre, at: 1)
        if anchorIndex >= 1 { anchorIndex += 1 }
        // One more head means one more `step` of room the chain needs; without
        // this the tail is pinned at the screen edge and never reaches rest.
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        wake()
    }

    private func removeBubble(at i: Int) {
        guard bubbles.indices.contains(i) else { return }
        retire(bubbles.remove(at: i))
        centres.remove(at: i)
        velocities.remove(at: i)
        diameters.remove(at: i)
        hoverTargets.remove(at: i)
        born.remove(at: i)
        if anchorIndex >= bubbles.count { anchorIndex = max(0, bubbles.count - 1) }
    }


    /// Adopt the app's live web view. Messenger is already loaded in it, so the
    /// first bubble opens instantly instead of waiting out a second cold boot
    /// of the whole SPA — and only one copy renders from then on.
    private func adopt(_ wv: WKWebView) {
        webView = wv
        // Only the URL is observed: the navigation and UI delegates stay with
        // the main controller, so downloads, offline handling and the
        // notification bridge keep working exactly as they do in window mode.
        wv.addObserver(self, forKeyPath: "URL", options: [.new], context: nil)
        observingURL = true
    }

    /// Give it back before the main window needs it again.
    private func release() {
        guard observingURL, let wv = webView else { return }
        wv.removeObserver(self, forKeyPath: "URL")
        observingURL = false
        wv.removeFromSuperview()
    }

    private var observingURL = false

    /// Put `view` in the card with an even margin on every side.
    ///
    /// The web view is the exception: it is laid out WIDER than the card and
    /// pushed left by `sidebarInset`, so Messenger's icon rail and conversation
    /// list fall outside the card's bounds. Hiding them with CSS cannot work —
    /// Messenger reserves the rail (44pt) and the list (356pt) first and only
    /// renders the conversation in what is left, so at a card-sized viewport
    /// `[role="main"]` comes back 0pt tall and there is nothing to reveal.
    /// Giving the page a wide viewport and clipping is the only version of this
    /// that has no race and nothing to blank.
    private func installContent(_ view: NSView) {
        guard let content = card.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.removeAnimation(forKey: "plume.fold")
        content.layer?.transform = CATransform3DIdentity
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        let m = Self.inset
        var rules = [
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
        ]
        if view === webView {
            let lead = view.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                     constant: m - sidebarInset)
            sidebarConstraint = lead
            rules.append(lead)
        } else {
            sidebarConstraint = nil
            rules.append(view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m))
        }
        NSLayoutConstraint.activate(rules)
    }

    /// How far Messenger's chrome column extends from the left edge of the
    /// page. Seeded with what the real DOM reports and re-measured after every
    /// load, so a Messenger redesign corrects itself instead of breaking.
    private var sidebarInset: CGFloat = 432
    private var sidebarConstraint: NSLayoutConstraint?

    private var lastMeasuredInset: CGFloat = 0
    private var stableMeasurements = 0

    private func measureSidebar() {
        let js = """
        (function () {
          // The conversation's own left edge is the exact answer, and it is
          // only trustworthy once the conversation has actually rendered.
          var main = document.querySelector('[role="main"]');
          if (main) {
            var b = main.getBoundingClientRect();
            if (b.height > 120 && b.left > 100) return Math.round(b.left);
          }
          // Otherwise fall back to where Messenger's chrome column ends.
          var edge = 0;
          document.querySelectorAll('[role="navigation"]').forEach(function (n) {
            if (main && n.contains(main)) return;          // it wraps the thread: not chrome
            var r = n.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) edge = Math.max(edge, r.right);
          });
          return edge;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            // Ignore nonsense: a mid-render zero, or a value so large the card
            // would show nothing at all.
            guard let self, let edge = result as? Double, edge > 100, edge < 700 else { return }
            let inset = CGFloat(edge.rounded())
            guard abs(inset - self.sidebarInset) > 1 else { return }
            if abs(inset - self.lastMeasuredInset) < 1 {
                self.stableMeasurements += 1
                // Two identical readings after the page settled: stop asking.
                if self.stableMeasurements >= 2 {
                    self.fixupWork.forEach { $0.cancel() }
                    self.fixupWork.removeAll()
                }
            } else {
                self.stableMeasurements = 0
            }
            self.lastMeasuredInset = inset
            self.sidebarInset = inset
            self.sidebarConstraint?.constant = Self.inset - inset
        }
    }

    private func saveCardSize() {
        // Content size both ways: `applyThreadSize` restores with
        // `setContentSize`, and mixing the two drifts by the titlebar's height
        // on every open.
        let s = card.contentRect(forFrameRect: card.frame).size
        UserDefaults.standard.set(["w": s.width, "h": s.height], forKey: Self.sizeKey)
    }

    @objc private func exitBubbleMode() { onExitBubbleMode?() }

    /// Right-click on the app chip. Everything that would otherwise need chrome
    /// glued over the card lives here instead, so the card stays nothing but
    /// the conversation.
    private func showChipMenu(from view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let back = NSMenuItem(title: L.t("Về cửa sổ chính", "Back to the Main Window"),
                              action: #selector(exitBubbleMode), keyEquivalent: "")
        back.target = self
        menu.addItem(back)
        menu.addItem(.separator())

        let limits = NSMenu()
        for n in [3, 5, 8, 12] {
            let item = NSMenuItem(title: "\(n)", action: #selector(pickLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = n
            item.state = Preferences.bubbleLimit == n ? .on : .off
            limits.addItem(item)
        }
        let limitItem = NSMenuItem(title: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                   action: nil, keyEquivalent: "")
        limitItem.submenu = limits
        menu.addItem(limitItem)

        let sizes = NSMenu()
        for (label, px) in [(L.t("Nhỏ", "Small"), 38), (L.t("Vừa", "Medium"), 46),
                            (L.t("Lớn", "Large"), 56), (L.t("Rất lớn", "Extra Large"), 66)] {
            let item = NSMenuItem(title: label, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = px
            item.state = Int(Preferences.bubbleSize) == px ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: L.t("Kích thước bong bóng", "Bubble Size"),
                                  action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard CGFloat(sender.tag) != Preferences.bubbleSize else { return }
        Preferences.bubbleSize = CGFloat(sender.tag)
        rebuildChain()
    }

    /// A panel's canvas is fixed at creation, so a new size means new panels.
    /// The conversations, their order and the chain's anchor all survive.
    private func rebuildChain() {
        let convos = bubbles.dropFirst().compactMap { conversation(of: $0) }
        let head = centres.first ?? savedHeadCentre()
        bubbles.forEach(retire)
        bubbles.removeAll()
        centres.removeAll(); velocities.removeAll()
        diameters.removeAll(); hoverTargets.removeAll(); born.removeAll()
        anchorIndex = 0
        for (i, convo) in ([nil] + convos.map { Optional($0) }).enumerated() {
            appendBubble(convo, centre: NSPoint(x: head.x, y: head.y - CGFloat(i) * Chain.step))
        }
        anchorTarget = clampedAnchor(head)
        wake()
        applyTotalBadge()
        refreshUnreadFlags()      // new chips start from the stored snapshot
    }

    @objc private func pickLimit(_ sender: NSMenuItem) {
        Preferences.bubbleLimit = sender.tag
        applyBubbleLimit()
    }

    /// Trim the chain to the current limit. Contacts are bubbles[1...], oldest
    /// last. Called from both menus that offer the setting.
    func applyBubbleLimit() {
        while bubbles.count - 1 > Preferences.bubbleLimit, bubbles.count > 1 {
            removeBubble(at: bubbles.count - 1)
        }
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        wake()
    }

    // MARK: Open / collapse

    /// Show a conversation in the shared card. One web view serves every
    /// bubble, so adding bubbles costs a window, not a web process.
    private func open(_ convo: BubbleConversation?) {
        collapseWork?.cancel(); collapseWork = nil
        PlumeTrace.log("\n===== open(\(convo?.name ?? "APP")) =====")
        for (i, sc) in NSScreen.screens.enumerated() {
            PlumeTrace.log("  screen[\(i)] frame=\(PlumeTrace.r(sc.frame)) visible=\(PlumeTrace.r(sc.visibleFrame))")
        }
        PlumeTrace.log("  mouse=\(PlumeTrace.p(NSEvent.mouseLocation)) main=\(PlumeTrace.r(NSScreen.main?.frame ?? .zero))")
        PlumeTrace.log("  panel[0].frame=\(PlumeTrace.r(bubbles.first?.frame ?? .zero)) panel[0].screen=\(PlumeTrace.r(bubbles.first?.screen?.frame ?? .zero))")
        PlumeTrace.log("  lastOpened=\(lastOpenedIndex) panel[i].frame=\(PlumeTrace.r(bubbles.indices.contains(lastOpenedIndex) ? bubbles[lastOpenedIndex].frame : .zero))")
        PlumeTrace.log("  centres[0] TRƯỚC sync=\(PlumeTrace.p(centres.first ?? .zero))")
        // Before anything is placed relative to a bubble: find out where the
        // bubbles really are, and follow the user to the display they are on.
        syncCentresFromPanels()
        PlumeTrace.log("  centres[0] SAU sync=\(PlumeTrace.p(centres.first ?? .zero))")
        adoptScreenUnderCursor()
        PlumeTrace.log("  centres[0] SAU adopt=\(PlumeTrace.p(centres.first ?? .zero)) anchorTarget=\(PlumeTrace.p(anchorTarget))")
        PlumeTrace.log("  card TRƯỚC=\(PlumeTrace.r(card.frame)) cardScreen=\(PlumeTrace.r(card.screen?.frame ?? .zero)) visible=\(card.isVisible) docked=\(docked)")
        // Same bubble twice = close it again. With the traffic lights hidden
        // this is the card's dismiss affordance.
        // Compare with what the card is ACTUALLY showing: a swipe-back or a
        // link inside the card leaves `currentThread` behind, and then clicking
        // that head folds the card away instead of returning to it.
        let live = ThreadURL.canonical(from: webView.url)
        if isExpanded, card.isVisible,
           (convo == nil && showingPicker) || (convo != nil && convo?.url == live) {
            collapse(); return
        }
        if let convo {
            showThread(convo.url)
            // Reading it clears it; don't make the user wait for the next snapshot.
            bubbles.first { conversation(of: $0)?.url == convo.url }
                .flatMap { chip($0) }?.setBadge(nil)
        } else {
            showPicker()
        }
        // Place the card under the chain whenever it is appearing or the chain
        // changed display. While already docked on the same display, leave the
        // user's dragged position alone.
        let cardMid = NSPoint(x: card.frame.midX, y: card.frame.midY)
        if !card.isVisible || !docked
            || screen(nearest: cardMid) !== screen(nearest: centres.first ?? cardMid) {
            positionCard()
            PlumeTrace.log("  -> positionCard()")
        } else {
            keepCardOnScreen()
            PlumeTrace.log("  -> keepCardOnScreen()")
        }
        PlumeTrace.log("  card SAU=\(PlumeTrace.r(card.frame)) cardScreen=\(PlumeTrace.r(card.screen?.frame ?? .zero))")
        isExpanded = true
        docked = true
        wake()
        // A short fade, deliberately not a frame animation: growing a window
        // that holds a live WKWebView re-lays-out the page on every frame, so
        // the "nice" opening animation is the slow one.
        card.contentView?.layer?.removeAnimation(forKey: "plume.fold")
        card.contentView?.layer?.transform = CATransform3DIdentity
        card.alphaValue = 0
        card.makeKeyAndOrderFront(nil)
        // Unfold: a small scale on the content LAYER, mirroring the fold. A
        // window-frame animation would re-lay-out the page on every frame,
        // which is what made the "nice" opening the slow one.
        if let layer = card.contentView?.layer {
            let f = card.frame
            let c = CGPoint(x: f.width / 2, y: f.height / 2)
            var from = CATransform3DMakeTranslation(c.x, c.y, 0)
            from = CATransform3DScale(from, 0.94, 0.94, 1)
            from = CATransform3DTranslate(from, -c.x, -c.y, 0)
            let unfold = CABasicAnimation(keyPath: "transform")
            unfold.fromValue = from
            unfold.toValue = CATransform3DIdentity
            unfold.duration = 0.13
            unfold.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(unfold, forKey: "plume.unfold")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Escape a Swift string for safe interpolation into evaluated JavaScript.
    private static func jsonString(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Messenger settles asynchronously after a load, so the card's two
    /// adjustments are retried on a short ladder rather than fired once.
    private static let fixupDelays: [TimeInterval] = [0, 0.15, 0.4, 0.9, 1.6, 2.6, 4.0]
    private var fixupWork: [DispatchWorkItem] = []

    private func scheduleCardFixups() {
        fixupWork.forEach { $0.cancel() }
        fixupWork.removeAll()
        stableMeasurements = 0
        for delay in Self.fixupDelays {
            let work = DispatchWorkItem { [weak self] in
                self?.measureSidebar()
                self?.hideSkipLinks()
            }
            fixupWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Messenger's "skip to main content" link is focus-revealed and lands over
    /// the conversation in a card this narrow.
    /// Fired only in the moment after a thread switch, so it can never fight a
    /// reader who has deliberately scrolled back through the conversation.
    private func scrollToLatest() {
        webView.evaluateJavaScript("window.__plumeScrollToLatest && window.__plumeScrollToLatest()",
                                   completionHandler: nil)
    }

    private func hideSkipLinks() {
        webView.evaluateJavaScript("window.__plumeHideSkipLinks && window.__plumeHideSkipLinks()",
                                   completionHandler: nil)
    }

    private func showThread(_ url: URL) {
        showingPicker = false
        applyThreadSize()
        if card.isVisible { keepCardOnScreen() }
        installContent(webView)
        currentThread = url
        scheduleCardFixups()
        for delay in [0.25, 0.7, 1.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scrollToLatest()
            }
        }
        // Compare against what the web view is ACTUALLY showing, not against a
        // remembered value: navigating inside the card (Messenger's own back
        // button, for one) leaves `currentThread` pointing at a thread the view
        // has since left, so a remembered-value check would never reload.
        guard ThreadURL.canonical(from: webView.url) != url else { return }

        // A full load rebuilds the whole Messenger app and costs seconds. If
        // the view already has Messenger up, click the conversation's own row
        // instead — the same transition a user would make, and instant.
        if let live = webView.url, Plume.isInternal(live),
           let hrefJSON = Self.jsonString(url.absoluteString) {
            webView.evaluateJavaScript("window.__plumeOpenThread(\(hrefJSON))") {
                [weak self] result, _ in
                guard let self, (result as? Bool) != true else { return }
                self.webView.load(URLRequest(url: url))   // row not found: fall back
            }
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// The app chip opens our own list — Messenger's inbox URL immediately
    /// redirects into the most recent conversation, so its list can't be shown.
    private func showPicker() {
        currentThread = nil
        showingPicker = true
        // Size against the chain's display — `card.screen` still names the old
        // one while the card is ordered out or mid-hop between monitors.
        let visible = hostScreen.visibleFrame
        card.setContentSize(NSSize(
            width: min(Self.pickerSize.width, visible.width - 16),
            height: min(Self.pickerSize.height, visible.height - Chain.canvas - 28)))
        if card.isVisible { keepCardOnScreen() }
        listView.onPick = { [weak self] convo in
            guard let self else { return }
            self.spawnBubble(for: convo)
            // Look the head up rather than assuming index 1: spawnBubble is a
            // no-op when that contact already has one, and the card would then
            // fold down onto somebody else's bubble.
            self.lastOpenedIndex = self.bubbles.firstIndex {
                self.conversation(of: $0)?.url == convo.url
            } ?? 0
            self.showThread(convo.url)
        }
        installContent(listView)
        fetchConversations?(Preferences.bubbleLimit * 3) { [weak self] convos in
            self?.listView.set(convos)
        }
    }

    /// Back to bubbles. Ordering the card out and detaching the web view is what
    /// lets WebKit stop rendering it; the view itself stays alive so messages
    /// keep arriving and reopening is instant.
    /// Back to bubbles: the card folds down towards the head it came from.
    ///
    /// This animates the content LAYER, never the window frame. Frame animation
    /// meant restoring the size afterwards, and any path that missed the restore
    /// left the card stranded at the fold-down size — a small square on the next
    /// open. It also re-laid-out the web page on every frame. A layer transform
    /// does neither: the frame is untouched throughout, so there is nothing to
    /// put back.
    func collapse() {
        guard isExpanded else { return }
        collapseWork?.cancel(); collapseWork = nil
        isExpanded = false
        docked = false
        wake()                              // the chain flies home to its column
        bubbles.forEach { $0.orderFront(nil) }
        refreshUnreadFlags()

        let duration = 0.13
        if let layer = card.contentView?.layer {
            layer.removeAnimation(forKey: "plume.unfold")
            let f = card.frame
            let t = shrinkTarget()
            let c = CGPoint(x: f.width / 2, y: f.height / 2)
            // Scale about the card's own centre, drifting towards the bubble.
            var to = CATransform3DMakeTranslation(c.x, c.y, 0)
            to = CATransform3DTranslate(to, t.midX - f.midX, t.midY - f.midY, 0)
            to = CATransform3DScale(to, 0.08, 0.08, 1)
            to = CATransform3DTranslate(to, -c.x, -c.y, 0)

            let fold = CABasicAnimation(keyPath: "transform")
            fold.fromValue = CATransform3DIdentity
            fold.toValue = to
            fold.duration = duration
            fold.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fold.fillMode = .forwards
            fold.isRemovedOnCompletion = false
            layer.add(fold, forKey: "plume.fold")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            card.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, !self.isExpanded else { return }   // reopened mid-fold
            self.card.orderOut(nil)
            // Detach: this is what lets WebKit stop rendering the card. The web
            // view itself stays alive, so messages keep arriving and reopening
            // is instant.
            self.webView.removeFromSuperview()
            self.card.contentView?.layer?.removeAnimation(forKey: "plume.fold")
            self.card.contentView?.layer?.transform = CATransform3DIdentity
            self.card.alphaValue = 1
        }
    }

    /// Where the card folds down to: the bubble it was opened from.
    private func shrinkTarget() -> NSRect {
        let i = min(max(lastOpenedIndex, 0), max(0, centres.count - 1))
        let c = centres.indices.contains(i)
            ? centres[i]
            : NSPoint(x: card.frame.midX, y: card.frame.midY)
        let d = Chain.base
        return NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }

    private func dismiss() {
        release()
        NotificationCenter.default.removeObserver(self)
        unreadWork?.cancel(); unreadWork = nil
        docked = false
        teardownLoop()
        fixupWork.forEach { $0.cancel() }
        fixupWork.removeAll()
        collapseWork?.cancel(); collapseWork = nil
        webView.removeFromSuperview()
        card.orderOut(nil)
        bubbles.forEach(retire)
        bubbles.removeAll()
        centres.removeAll(); velocities.removeAll()
        diameters.removeAll(); hoverTargets.removeAll(); born.removeAll()
    }

    /// Re-read where the window server actually put the heads.
    ///
    /// `centres` is our model, and it can drift from reality: these panels join
    /// all Spaces, so the system can show them on the display the user has
    /// moved to. Anything that positions something relative to a bubble has to
    /// start from the truth, not from the model.
    private func syncCentresFromPanels() {
        guard centres.count == bubbles.count else { return }
        for i in bubbles.indices {
            let f = bubbles[i].frame
            centres[i] = NSPoint(x: f.midX, y: f.midY)
        }
    }

    /// Bring the chain onto the display the user is actually working on.
    ///
    /// A click just landed on a bubble, so the cursor is on the same display
    /// that bubble is visible on — and that is authoritative in a way our
    /// coordinates are not. Without this the card opened on whichever display
    /// the chain was last parked on while the bubbles appeared on another, and
    /// clicking a head seemed to do nothing at all.
    private func adoptScreenUnderCursor() {
        guard centres.first != nil else {
            PlumeTrace.log("  adopt: BỎ QUA (không có head)")
            return
        }
        // Same picker as everywhere else: `frame.contains` excludes the max
        // edge and falls through the dead zones between mismatched heights.
        let target = screen(nearest: NSEvent.mouseLocation)
        teleportChain(to: target, reason: "adopt")
    }

    /// Instantly re-park the whole chain onto `target`, keeping the edge and
    /// relative height it had on the old display. Springing across the gap
    /// between monitors reads as a glitch, not as motion.
    @discardableResult
    private func teleportChain(to target: NSScreen, reason: String) -> Bool {
        guard let head = centres.first else { return false }
        let current = screen(nearest: head)
        PlumeTrace.log("  teleport(\(reason)): from=\(PlumeTrace.r(current.frame)) to=\(PlumeTrace.r(target.frame)) giống nhau=\(target === current)")
        guard target !== current else { return false }

        let old = current.visibleFrame, new = target.visibleFrame
        let fx = old.width > 0 ? (head.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (head.y - old.minY) / old.height : 0.5
        anchorIndex = 0
        anchorTarget = clampedAnchor(NSPoint(x: new.minX + fx * new.width,
                                             y: new.minY + fy * new.height))
        for i in centres.indices {
            centres[i] = NSPoint(x: anchorTarget.x,
                                 y: anchorTarget.y - CGFloat(i) * Chain.step)
            velocities[i] = .zero
        }
        commit()
        saveAnchor()
        return true
    }

    private func positionCard() {
        // Tuck under the bubble that was just clicked — not always the app chip.
        let i = min(max(lastOpenedIndex, 0), max(0, centres.count - 1))
        let head = centres.indices.contains(i)
            ? centres[i]
            : (centres.first ?? NSPoint(x: card.frame.midX, y: card.frame.midY))
        let visible = screen(nearest: head).visibleFrame
        let size = card.frame.size
        // The card hangs below the head, with a clear lane above it for the
        // docked row — the row is part of the window's furniture now, so the
        // card must never be pushed so high that the row leaves the screen.
        let lane = Chain.canvas + 12
        // Prefer keeping the head above the card: near the right edge align the
        // card's right side, otherwise its left. Clamping alone would shove a
        // right-edge open hundreds of points left and then yank the chain after it.
        var origin = NSPoint(x: 0, y: head.y - Chain.canvas / 2 - 10 - size.height)
        if head.x > visible.midX {
            origin.x = head.x + Chain.canvas / 2 - size.width
        } else {
            origin.x = head.x - Chain.canvas / 2
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8),
                       visible.maxY - size.height - lane)
        let dest = NSRect(origin: origin, size: size)
        let destScreen = screen(nearest: NSPoint(x: dest.midX, y: dest.midY))
        PlumeTrace.log("  positionCard want=\(PlumeTrace.r(dest)) visible=\(PlumeTrace.r(visible)) destScreen=\(PlumeTrace.r(destScreen.frame))")
        // orderOut first when hopping displays: even with constrainFrameRect
        // overridden, a visible panel can keep its old screen association for
        // one turn and paint on the wrong monitor.
        if card.screen !== destScreen, card.screen != nil {
            card.orderOut(nil)
        }
        card.setFrame(dest, display: false)
        PlumeTrace.log("  positionCard got=\(PlumeTrace.r(card.frame)) screen=\(PlumeTrace.r(card.screen?.frame ?? .zero))")
    }

    /// Resizing keeps the bottom-left corner, so a taller card grows up into
    /// the lane the docked row lives in. Push it back down.
    private func keepCardOnScreen() {
        // Midpoint, not `card.screen`: after a cross-display setFrame the
        // screen property can lag one event loop behind the frame.
        let visible = screen(nearest: NSPoint(x: card.frame.midX, y: card.frame.midY)).visibleFrame
        let size = card.frame.size
        var origin = card.frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8),
                       visible.maxY - size.height - Chain.canvas - 12)
        guard origin != card.frame.origin else { return }
        card.setFrameOrigin(origin)
    }

    /// The docked row rides the card, so any card movement has to wake the loop.
    func windowDidMove(_ notification: Notification) {
        guard docked else { return }
        keepCardOnScreen()      // the row hangs off the card's top edge
        wake()
    }
    func windowDidResize(_ notification: Notification) {
        guard docked else { return }
        keepCardOnScreen()
        wake()
    }

    // MARK: Auto-collapse

    func windowDidResignKey(_ notification: Notification) {
        guard isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded, !self.card.isKeyWindow else { return }
            self.collapse()
        }
        collapseWork?.cancel()
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        collapseWork?.cancel(); collapseWork = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }

    /// Keep whatever size the user settles on — a chat card is personal, and
    /// re-imposing our default on every open would be a nuisance.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !showingPicker else { return }   // the picker has a size of its own
        saveCardSize()
        // A different width is a different viewport, so Messenger lays its
        // chrome column out differently — the offset that hides it has to be
        // measured again or the conversation sits shifted in the card.
        scheduleCardFixups()
    }

    /// The size a conversation gets. Unlike `restoreCardSize` this never
    /// no-ops: leaving the card at the picker's width made Messenger collapse
    /// `[role="main"]` to zero height, which is what a black card actually is.
    private func applyThreadSize() {
        var size = Self.cardSize
        if let saved = UserDefaults.standard.dictionary(forKey: Self.sizeKey),
           let w = saved["w"] as? Double, let h = saved["h"] as? Double {
            size = NSSize(width: w, height: h)
        }
        // Size against the chain's display — `card.screen` still names the old
        // one while the card is ordered out or mid-hop between monitors.
        let visible = hostScreen.visibleFrame
        let lane = Chain.canvas + 28          // the docked row has to fit above it
        size.width = min(max(size.width, card.minSize.width), visible.width - 16)
        size.height = min(max(size.height, card.minSize.height), visible.height - lane)
        if card.contentRect(forFrameRect: card.frame).size != size {
            card.setContentSize(size)
            scheduleCardFixups()      // new viewport, new chrome width
        }
    }

    private func restoreCardSize() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.sizeKey),
              let w = saved["w"] as? Double, let h = saved["h"] as? Double
        else { return }
        let visible = hostScreen.visibleFrame
        let size = NSSize(width: min(max(w, card.minSize.width), visible.width),
                          height: min(max(h, card.minSize.height), visible.height))
        card.setContentSize(size)
    }

    // MARK: - Chain physics
    //
    // Android chat heads: whichever bubble you grab is pinned to the cursor and
    // the rest of the chain trails it on springs, then the whole chain flies to
    // the nearest screen edge when you let go. One display link drives every
    // window and parks itself the moment nothing moves — a chain at rest costs
    // nothing at all.
    //
    // The trail is a damped spring with velocity state, not exponential
    // smoothing. Smoothing lags prettily but can never overshoot, and the
    // overshoot is exactly what reads as mass: when the cursor stops, the tail
    // keeps coming, bunches up, and settles back.

    private var centres: [NSPoint] = []
    private var velocities: [NSPoint] = []
    private var diameters: [CGFloat] = []
    private var hoverTargets: [CGFloat] = []
    private var born: [CFTimeInterval] = []
    /// The bubble the chain hangs from — index 0, or whichever one is dragged.
    private var anchorIndex = 0
    private var anchorTarget: NSPoint = .zero
    /// While the card is open the chain leaves its column and docks in a row
    /// along the top of it, so any conversation is one click away.
    private var docked = false
    private var dragging = false
    private var dragGrabOffset: NSPoint = .zero
    private var dragCursor: NSPoint = .zero

    /// CADisplayLink retains its target and the run loop retains the link, so
    /// `target: self` is a permanent cycle. The proxy is the only way out.
    private final class LinkProxy: NSObject {
        weak var owner: ChatBubbleController?
        init(_ o: ChatBubbleController) { owner = o }
        @objc func onFrame(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private var link: CADisplayLink?
    private var linkProxy: LinkProxy?
    private var linkScreen: NSScreen?
    private var lastFrame: CFTimeInterval = 0      // 0 = sentinel, not a timestamp
    private var idleFrames = 0
    private var mouseMonitors: [Any] = []
    /// Debounced hop onto the display the cursor is on — matches the user's
    /// expectation that bubbles follow the active screen, and keeps `centres`
    /// honest so the card opens there too.
    private var followScreenWork: DispatchWorkItem?
    /// Polls `mouseLocation` while bubble mode is live. Global mouse monitors
    /// silently drop events across display boundaries on current macOS (and
    /// need Accessibility for some paths); a 30 Hz poll needs neither and is
    /// what actually lets a drag finish on the other screen.
    private var mousePoll: Timer?
    private var foreignScreenTicks = 0

    private func index(of panel: BubblePanel) -> Int? {
        bubbles.firstIndex { $0 === panel }
    }

    // MARK: Frame loop

    /// Idempotent. Call from every event that creates motion — never poll.
    private func wake() {
        guard !bubbles.isEmpty else { return }
        // If the system relocated a parked panel, the first thing the loop would
        // otherwise do is drag it back to where the model remembers it.
        if link == nil || link?.isPaused == true { syncCentresFromPanels() }
        idleFrames = 0
        if let link, linkScreen === anchorScreen {
            if link.isPaused { lastFrame = 0; link.isPaused = false }
            return
        }
        arm(on: anchorScreen)
    }

    /// Package.swift pins macOS 14, where `displayLink(target:selector:)` exists
    /// on NSView, NSWindow *and* NSScreen — so no availability branch and no
    /// CVDisplayLink. The screen variant is the right host: a view-hosted link
    /// stops firing when its view is hidden or its panel is ordered out, which
    /// would freeze the chain mid-animation with nothing to restart it.
    private func arm(on screen: NSScreen) {
        link?.invalidate()
        let proxy = linkProxy ?? LinkProxy(self)
        linkProxy = proxy
        let l = screen.displayLink(target: proxy, selector: #selector(LinkProxy.onFrame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        // .common, or the chain freezes for the whole drag: a mouse drag runs
        // the run loop in .eventTracking.
        l.add(to: .main, forMode: .common)
        lastFrame = 0
        link = l
        linkScreen = screen
    }

    /// Zero-cost idle: no callback, no main-thread wakeup, instant resume.
    /// Never invalidate here, or every hover in and out pays for a fresh link.
    private func park() {
        link?.isPaused = true
        lastFrame = 0
    }

    private func teardownLoop() {
        link?.invalidate(); link = nil
        linkProxy = nil; linkScreen = nil
        followScreenWork?.cancel(); followScreenWork = nil
        stopMousePoll()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    private func startMousePoll() {
        guard mousePoll == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        mousePoll = t
    }

    private func stopMousePoll() {
        mousePoll?.invalidate()
        mousePoll = nil
        foreignScreenTicks = 0
    }

    private func pollMouse() {
        let p = NSEvent.mouseLocation
        if dragging {
            // Button released on another display never reaches the chip view.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                PlumeTrace.log("  drag mouseUp@\(PlumeTrace.p(p)) via poll")
                endDrag(velocity: dragFlickVelocity())
            } else {
                dragTo(p)
            }
            return
        }
        let before = hoverTargets
        recomputeHoverTargets()
        if before != hoverTargets { wake() }
        followCursorScreenIfNeeded()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard !bubbles.isEmpty else { park(); return }

        // targetTimestamp deltas, never link.duration: duration is the display's
        // fastest frame and stays 1/120 on ProMotion even while the link runs at
        // 60, which would halve every animation. On the first frame after a wake
        // there is no previous target, so fall back to the nominal interval —
        // link.timestamp is 0 before the link has ever fired.
        let now = link.targetTimestamp
        let nominal = link.targetTimestamp - link.timestamp
        let raw = lastFrame == 0 ? nominal : now - lastFrame
        lastFrame = now
        let dt = CGFloat(min(max(raw, Double(Chain.dtMin)), Double(Chain.dtMax)))

        refreshHover()
        var moving = integrate(dt: dt, now: now)
        moving = advanceMagnification(dt: dt) || moving
        commit()

        if moving { idleFrames = 0 }
        else {
            idleFrames += 1
            if idleFrames > 2 {
                snapToRest(anchor: min(anchorIndex, bubbles.count - 1))
                park()
            }
        }
        if linkScreen !== anchorScreen { arm(on: anchorScreen) }
    }

    /// Where each head sits while the card is open: a row across the top of it,
    /// app chip first. Recomputed every frame, so the row rides the card when it
    /// is dragged or resized.
    private func rowSlots() -> [NSPoint] {
        let f = card.frame
        let visible = screen(nearest: NSPoint(x: f.midX, y: f.midY)).visibleFrame
        let half = Chain.canvas / 2
        let y = min(f.maxY + 8 + half, visible.maxY - half - 2)
        let minX0 = f.minX + half + 8
        let span = CGFloat(max(0, bubbles.count - 1)) * Chain.step
        let maxX0 = f.maxX - half - 8 - span
        // Keep the head near where it already is so opening the card does not
        // yank the whole chain across the display to the card's left edge.
        let preferred = centres.first?.x ?? minX0
        let x0 = minX0 <= maxX0
            ? min(max(preferred, minX0), maxX0)
            : minX0
        return bubbles.indices.map {
            NSPoint(x: min(x0 + CGFloat($0) * Chain.step, visible.maxX - half - 2), y: y)
        }
    }

    /// One physics step. Returns true while anything is still moving.
    private func integrate(dt: CGFloat, now: CFTimeInterval) -> Bool {
        if docked, card.isVisible {
            // Every head flies to its own slot rather than chasing the one in
            // front: a chain would arrive as a whip, and this is a toolbar.
            // The per-index τ ramp still lands them in a cascade.
            let slots = rowSlots()
            var moving = false
            for i in bubbles.indices {
                let t = slots[i]
                let w = 2 * Chain.trailZeta / Chain.trailTau(i + 1)
                Chain.spring(&centres[i].x, &velocities[i].x, to: t.x,
                             omega: w, zeta: Chain.trailZeta, dt: dt)
                Chain.spring(&centres[i].y, &velocities[i].y, to: t.y,
                             omega: w, zeta: Chain.trailZeta, dt: dt)
                if abs(centres[i].x - t.x) > Chain.restDistance
                    || abs(centres[i].y - t.y) > Chain.restDistance { moving = true }
            }
            if born.contains(where: { now < $0 }) { moving = true }
            return moving
        }
        let a = min(anchorIndex, bubbles.count - 1)
        let half = Chain.canvas / 2

        if dragging {
            centres[a] = NSPoint(x: dragCursor.x + dragGrabOffset.x,
                                 y: dragCursor.y + dragGrabOffset.y)
            velocities[a] = .zero
        } else {
            // At rest the whole chain shares one display — the anchor's.
            let visible = anchorScreen.visibleFrame
            let loX = visible.minX + half + Chain.margin, hiX = visible.maxX - half - Chain.margin
            let loY = visible.minY + half + Chain.margin, hiY = visible.maxY - half - Chain.margin
            Chain.spring(&centres[a].x, &velocities[a].x, to: anchorTarget.x,
                         omega: Chain.anchorOmega, zeta: Chain.anchorZeta, dt: dt)
            Chain.spring(&centres[a].y, &velocities[a].y, to: anchorTarget.y,
                         omega: Chain.anchorOmega, zeta: Chain.anchorZeta, dt: dt)
            // The flick is carried into the spring, so ζ 0.9 still overshoots.
            // Allow a visible settle, never a bubble off the screen.
            Chain.clamp(&centres[a].x, &velocities[a].x,
                        loX - Chain.maxOvershoot, hiX + Chain.maxOvershoot)
            Chain.clamp(&centres[a].y, &velocities[a].y,
                        loY - Chain.maxOvershoot, hiY + Chain.maxOvershoot)
        }

        var moving = dragging
        func band(around p: NSPoint, overshoot: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            // Per-bubble screen: a single shared band pinned the tail to the
            // old display while the head crossed into the next one.
            let visible = screen(nearest: p).visibleFrame
            return (visible.minX + half + Chain.margin - overshoot,
                    visible.maxX - half - Chain.margin + overshoot,
                    visible.minY + half + Chain.margin - overshoot,
                    visible.maxY - half - Chain.margin + overshoot)
        }
        func follow(_ i: Int, leader: Int, k: Int, dy: CGFloat) {
            let tx = centres[leader].x, ty = centres[leader].y + dy
            let w = 2 * Chain.trailZeta / Chain.trailTau(k)
            Chain.spring(&centres[i].x, &velocities[i].x, to: tx,
                         omega: w, zeta: Chain.trailZeta, dt: dt)
            Chain.spring(&centres[i].y, &velocities[i].y, to: ty,
                         omega: w, zeta: Chain.trailZeta, dt: dt)

            // Rope constraint. Cumulative lag down a six-chain is ~0.33s; at
            // 1500pt/s the tail would sit hundreds of points behind and leave
            // the screen. The spring alone cannot bound that — clamp the link
            // and kill the outward velocity so the tail stops fighting the rope.
            var dx = centres[i].x - tx, dyy = centres[i].y - ty
            let dist = (dx * dx + dyy * dyy).squareRoot()
            if dist > Chain.maxLink, dist > 0 {
                let s = Chain.maxLink / dist
                dx *= s; dyy *= s
                centres[i] = NSPoint(x: tx + dx, y: ty + dyy)
                let nx = dx / Chain.maxLink, ny = dyy / Chain.maxLink
                let outward = velocities[i].x * nx + velocities[i].y * ny
                if outward > 0 {
                    velocities[i].x -= outward * nx
                    velocities[i].y -= outward * ny
                }
            }
            // Followers get no overshoot budget: hard clamp to THEIR screen.
            let (loX, hiX, loY, hiY) = band(around: centres[i], overshoot: 0)
            Chain.clamp(&centres[i].x, &velocities[i].x, loX, hiX)
            Chain.clamp(&centres[i].y, &velocities[i].y, loY, hiY)

            // Against the clamped target, not the raw one: a target outside
            // the screen band is unreachable, and comparing to it would keep
            // `moving` true forever.
            let rx = min(max(tx, loX), hiX), ry = min(max(ty, loY), hiY)
            if abs(centres[i].x - rx) > Chain.restDistance
                || abs(centres[i].y - ry) > Chain.restDistance { moving = true }
        }
        if a > 0 {
            for i in stride(from: a - 1, through: 0, by: -1) {
                follow(i, leader: i + 1, k: a - i, dy: Chain.step)
            }
        }
        if a < bubbles.count - 1 {
            for i in (a + 1)..<bubbles.count {
                follow(i, leader: i - 1, k: i - a, dy: -Chain.step)
            }
        }

        if !dragging {
            let visible = anchorScreen.visibleFrame
            let loX = visible.minX + half + Chain.margin, hiX = visible.maxX - half - Chain.margin
            let loY = visible.minY + half + Chain.margin, hiY = visible.maxY - half - Chain.margin
            let ax = min(max(anchorTarget.x, loX - Chain.maxOvershoot), hiX + Chain.maxOvershoot)
            let ay = min(max(anchorTarget.y, loY - Chain.maxOvershoot), hiY + Chain.maxOvershoot)
            let rest = max(abs(centres[a].x - ax), abs(centres[a].y - ay))
            let speed = velocities.reduce(CGFloat(0)) { max($0, max(abs($1.x), abs($1.y))) }
            if rest > Chain.restDistance || speed > Chain.restSpeed { moving = true }
        }
        if born.contains(where: { now < $0 }) { moving = true }
        return moving
    }

    /// Six setFrameOrigin calls and six layer transforms. Nothing else belongs
    /// in a display-link callback — no layout, no display(), no image decode.
    private func commit() {
        for i in bubbles.indices {
            let panel = bubbles[i]
            let scale = max(panel.backingScaleFactor, 1)
            let o = NSPoint(x: centres[i].x - Chain.canvas / 2,
                            y: centres[i].y - Chain.canvas / 2)
            // Snap to the backing grid, not to integer points — rounding to
            // points throws away half the smoothness 120Hz just bought.
            let snapped = NSPoint(x: (o.x * scale).rounded() / scale,
                                  y: (o.y * scale).rounded() / scale)
            let dest = NSRect(origin: snapped, size: panel.frame.size)
            let destScreen = screen(nearest: centres[i])
            // Crossing displays: setFrameOrigin alone can leave the panel's
            // screen association on the old monitor. setFrame forces the hop.
            if panel.screen !== destScreen {
                panel.setFrame(dest, display: false)
                if !panel.isVisible { panel.orderFront(nil) }
            } else if snapped != panel.frame.origin {
                panel.setFrameOrigin(snapped)
            }
            (panel.contentView as? BubbleChipView)?.setDiameter(diameters[i])
        }
    }

    /// Land on exact pixels so a resting chain is perfectly aligned.
    private func snapToRest(anchor a: Int) {
        if docked, card.isVisible {
            centres = rowSlots()
            for i in velocities.indices { velocities[i] = .zero }
            commit()
            return          // the row is a temporary dock, not the chain's home
        }
        guard centres.indices.contains(a) else { return }
        centres[a] = anchorTarget
        for i in velocities.indices { velocities[i] = .zero }
        for i in stride(from: a - 1, through: 0, by: -1) {
            centres[i] = NSPoint(x: centres[i + 1].x, y: centres[i + 1].y + Chain.step)
        }
        if a < bubbles.count - 1 {
            for i in (a + 1)..<bubbles.count {
                centres[i] = NSPoint(x: centres[i - 1].x, y: centres[i - 1].y - Chain.step)
            }
        }
        commit()
        saveAnchor()
    }

    // MARK: Hover magnification

    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        // The bubbles float over other apps and the magnification field reaches
        // past every panel, so mouseMoved delivered to a key window is useless.
        // Global mouse monitors need no Accessibility grant — only keyboard ones do.
        //
        // leftMouseDragged + leftMouseUp are load-bearing for multi-display:
        // once the cursor leaves the screen the mouseDown landed on, the chip
        // view stops getting mouseDragged/mouseUp, so the chain freezes at the
        // edge and never completes the hop. The monitors keep feeding the drag.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] e in
            self?.handleMonitor(e)
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in
            self?.handleMonitor(e); return e
        }) { mouseMonitors.append(l) }
    }

    private func handleMonitor(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            // Idempotent with the chip's own mouseUp: whichever arrives first wins.
            if dragging {
                PlumeTrace.log("  drag mouseUp@\(PlumeTrace.p(NSEvent.mouseLocation)) via monitor")
                endDrag(velocity: dragFlickVelocity())
            }
        case .leftMouseDragged:
            if dragging { dragTo(NSEvent.mouseLocation) }
            cursorMoved()
        default:
            cursorMoved()
        }
    }

    /// Cheap enough for every mouse-moved event: it only wakes the loop when the
    /// answer actually changed, so a cursor elsewhere on screen costs nothing.
    private func cursorMoved() {
        let before = hoverTargets
        recomputeHoverTargets()
        if before != hoverTargets { wake() }
        followCursorScreenIfNeeded()
    }

    /// When the cursor parks on another display, bring the chain there. Without
    /// this the panels can look like they "jumped" (Spaces / active display)
    /// while their frames — and therefore the card — stay on the old one.
    private func followCursorScreenIfNeeded() {
        guard !dragging, !bubbles.isEmpty, let head = centres.first else {
            followScreenWork?.cancel(); followScreenWork = nil
            foreignScreenTicks = 0
            return
        }
        let target = screen(nearest: NSEvent.mouseLocation)
        let current = screen(nearest: head)
        guard target !== current else {
            followScreenWork?.cancel(); followScreenWork = nil
            foreignScreenTicks = 0
            return
        }
        // ~100ms of cursor on the other display (3 ticks at 30 Hz) before we
        // hop — long enough to cross the seam without teleports mid-gesture,
        // short enough to feel like the bubbles followed the user.
        foreignScreenTicks += 1
        guard foreignScreenTicks >= 3 else { return }
        foreignScreenTicks = 0
        PlumeTrace.log("\n===== follow-cursor mouse=\(PlumeTrace.p(NSEvent.mouseLocation)) =====")
        if teleportChain(to: target, reason: "follow-cursor") {
            if docked, card.isVisible {
                positionCard()
                card.orderFront(nil)
            }
            wake()
        }
    }

    /// Recomputed inside `tick` too, because the chain can slide under a cursor
    /// that never moves — an NSTrackingArea is only re-evaluated on pointer
    /// motion, so it would leave a flown-in bubble unmagnified forever.
    private func refreshHover() { recomputeHoverTargets() }

    /// Raised cosine over the live centres: bump(0)=1, bump(1)=0, zero slope at
    /// both ends, so there is no kink at the rim. Measuring against live
    /// positions is only safe because the canvas is fixed and `step` does not
    /// depend on scale — magnification never moves a bubble, so there is no
    /// scale → layout → distance → scale loop to oscillate in.
    private func recomputeHoverTargets() {
        hoverTargets = Array(repeating: Chain.base, count: bubbles.count)
        guard !dragging else { return }   // a held bubble squeezes; it does not magnify
        let p = NSEvent.mouseLocation
        let span = Chain.peak - Chain.base
        for i in bubbles.indices where i < centres.count {
            let u = hypot(centres[i].x - p.x, centres[i].y - p.y) / Chain.magRadius
            guard u < 1 else { continue }
            hoverTargets[i] = Chain.base + span * 0.5 * (1 + cos(.pi * u))
        }
    }

    private func advanceMagnification(dt: CGFloat) -> Bool {
        let k = 1 - exp(-Chain.magRate * dt)
        var moving = false
        let now = CACurrentMediaTime()
        for i in bubbles.indices {
            let want = now < born[i] ? 0 : hoverTargets[i]   // staggered pop-in
            if abs(want - diameters[i]) < Chain.magEpsilon { diameters[i] = want }
            else { diameters[i] += (want - diameters[i]) * k; moving = true }
        }
        return moving
    }

    // MARK: Gestures

    private var dragSamples: [(p: NSPoint, t: CFTimeInterval)] = []

    private func beginDrag(_ panel: BubblePanel, grab: NSPoint) {
        guard let i = index(of: panel) else { return }
        // Dragging a docked head undocks instantly so the chain can leave for
        // another display — otherwise the row is glued to the card and a
        // cross-screen drag is a no-op.
        if docked {
            collapseWork?.cancel(); collapseWork = nil
            isExpanded = false
            docked = false
            card.orderOut(nil)
            if let wv = webView { wv.removeFromSuperview() }
            anchorTarget = clampedAnchor(centres[i], index: i)
        }
        anchorIndex = i
        dragging = true
        dragCursor = grab
        dragGrabOffset = NSPoint(x: centres[i].x - grab.x, y: centres[i].y - grab.y)
        dragSamples = [(grab, CACurrentMediaTime())]
        foreignScreenTicks = 0
        PlumeTrace.log("\n===== dragBegan head=\(PlumeTrace.p(centres[i])) screen=\(PlumeTrace.r(screen(nearest: centres[i]).frame)) =====")
        wake()
    }

    private func dragTo(_ cursor: NSPoint) {
        guard dragging else { return }
        dragCursor = cursor
        let now = CACurrentMediaTime()
        dragSamples.append((cursor, now))
        if dragSamples.count > Chain.velSamples { dragSamples.removeFirst() }
        wake()
    }

    private func dragFlickVelocity() -> NSPoint {
        let now = CACurrentMediaTime()
        guard let last = dragSamples.last, now - last.t <= Chain.velStaleGate else { return .zero }
        let window = dragSamples.filter { last.t - $0.t <= Chain.velWindow }
        guard let first = window.first, window.count >= 2 else { return .zero }
        let span = last.t - first.t
        guard span >= Chain.velMinSpan else { return .zero }
        return NSPoint(x: (last.p.x - first.p.x) / CGFloat(span),
                       y: (last.p.y - first.p.y) / CGFloat(span))
    }

    /// Release: the flick is loaded straight into the anchor spring, which lands
    /// on the nearest edge and keeps the whole chain — not just the grabbed
    /// bubble — on screen.
    private func endDrag(velocity: NSPoint) {
        guard dragging else { return }   // idempotent; a stray call is a no-op
        dragging = false
        bubbles.forEach { ($0.contentView as? BubbleChipView)?.cancelPress() }
        let a = min(anchorIndex, max(0, bubbles.count - 1))
        guard centres.indices.contains(a) else { return }

        let v = NSPoint(x: max(-Chain.maxFlick, min(Chain.maxFlick, velocity.x)),
                        y: max(-Chain.maxFlick, min(Chain.maxFlick, velocity.y)))
        velocities[a] = v

        // Project first, then pick the screen from the projected point: a flick
        // aimed at the second display must snap to that display's edge, not the
        // one the cursor happened to be released over.
        let speed = hypot(v.x, v.y)
        let fast = speed >= Chain.flickFloor
        let px = centres[a].x + (fast ? v.x * Chain.projectTauX : 0)
        let py = centres[a].y + (fast ? v.y * Chain.projectTauY : 0)
        let visible = screen(nearest: NSPoint(x: px, y: py)).visibleFrame
        let half = Chain.canvas / 2
        let left = visible.minX + half + Chain.margin
        let right = visible.maxX - half - Chain.margin
        let above = CGFloat(a) * Chain.step
        let below = CGFloat(bubbles.count - 1 - a) * Chain.step
        let loY = visible.minY + half + Chain.margin + below
        let hiY = visible.maxY - half - Chain.margin - above
        anchorTarget = NSPoint(
            x: px < visible.midX ? left : right,
            // y is clamped, never snapped: snapping all four corners would take
            // away the freedom to park the chain at any height. If the chain is
            // taller than the usable band, top-align so bubble 0 stays visible.
            y: loY <= hiY ? min(max(py, loY), hiY) : hiY)
        PlumeTrace.log("  dragEnded cursor=\(PlumeTrace.p(NSEvent.mouseLocation)) head=\(PlumeTrace.p(centres[a])) target=\(PlumeTrace.p(anchorTarget)) screen=\(PlumeTrace.r(visible))")
        dragSamples.removeAll()
        wake()
    }

    /// The same band `integrate` clamps to. An anchor target outside it can
    /// never be reached, so the chain never comes to rest and the display link
    /// never parks — which is a 120Hz loop running forever.
    private func clampedAnchor(_ p: NSPoint, index a: Int = 0) -> NSPoint {
        let visible = screen(nearest: p).visibleFrame
        let half = Chain.canvas / 2
        let above = CGFloat(a) * Chain.step
        let below = CGFloat(max(0, bubbles.count - 1 - a)) * Chain.step
        let loY = visible.minY + half + Chain.margin + below
        let hiY = visible.maxY - half - Chain.margin - above
        return NSPoint(
            x: min(max(p.x, visible.minX + half + Chain.margin),
                   visible.maxX - half - Chain.margin),
            y: loY <= hiY ? min(max(p.y, loY), hiY) : hiY)
    }

    /// NSRect.contains excludes maxX/maxY, and displays of different heights
    /// leave dead zones in the global space, so `first { $0.frame.contains(p) }`
    /// silently falls through to NSScreen.main — a different display entirely,
    /// or nil when the app is not active. Pick by largest intersection.
    private func screen(nearest p: NSPoint) -> NSScreen {
        let rect = NSRect(x: p.x - Chain.canvas / 2, y: p.y - Chain.canvas / 2,
                          width: Chain.canvas, height: Chain.canvas)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        if let best { return best }
        return NSScreen.screens.min {
            hypot($0.frame.midX - p.x, $0.frame.midY - p.y)
                < hypot($1.frame.midX - p.x, $1.frame.midY - p.y)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var anchorScreen: NSScreen {
        screen(nearest: centres.indices.contains(anchorIndex)
               ? centres[anchorIndex] : (centres.first ?? .zero))
    }

    /// Display the chain (and therefore the card) should live on right now.
    private var hostScreen: NSScreen {
        screen(nearest: centres.first
               ?? NSPoint(x: card.frame.midX, y: card.frame.midY))
    }

    // MARK: Anchor persistence

    private func saveAnchor() {
        guard let c = centres.first else { return }
        UserDefaults.standard.set(["x": c.x, "y": c.y], forKey: Self.originKey)
    }

    private func savedHeadCentre() -> NSPoint {
        var c: NSPoint
        if let saved = UserDefaults.standard.dictionary(forKey: Self.originKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double {
            c = NSPoint(x: x, y: y)
        } else {
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            c = NSPoint(x: v.maxX - Chain.canvas / 2 - Chain.margin,
                        y: v.maxY - Chain.canvas / 2 - 80)
        }
        // Through the same clamp the simulation uses — a margin's difference
        // here is enough to make the chain unable to reach its own anchor.
        return clampedAnchor(c)
    }

    // MARK: Navigation
    //
    // The web view is on loan from WebViewController, which remains its
    // navigation and UI delegate — so link handling, downloads, offline
    // recovery and the notification bridge behave identically in bubble mode.
    // The card only needs to know when the page changes address.

    /// Messenger routes between threads without a navigation, so this is the
    /// only signal the card gets that the page moved.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "URL" { scheduleCardFixups() }
    }
}
