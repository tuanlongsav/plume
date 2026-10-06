import AppKit
import QuartzCore
import WebKit

// Diagnostic multi-display traces. No-op in release so notarized builds never
// write contact names / cursor positions to ~/plume-trace.log.
enum PlumeTrace {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("plume-trace.log")
    static func log(_ line: String) {
        #if DEBUG
        guard let d = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
        #endif
    }
    static func r(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
    static func p(_ p: NSPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}

/// Window level + Space membership for bubbles and the chat card.
///
/// `.statusWindow` / `.floating` sit *below* another app's fullscreen content.
/// `.screenSaver` is what actually stacks above a fullscreen Space; combined
/// with `fullScreenAuxiliary` + `canJoinAllSpaces` the panel joins that Space
/// instead of staying on the desktop Space behind it.
private enum PlumeOverlay {
    static let level = NSWindow.Level.screenSaver

    static var collectionBehavior: NSWindow.CollectionBehavior {
        var b: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]
        if #available(macOS 15.0, *) {
            b.insert(.canJoinAllApplications)
        }
        return b
    }

    static func apply(to window: NSWindow) {
        window.level = level
        window.collectionBehavior = collectionBehavior
        window.hidesOnDeactivate = false
    }
}

/// Raises AppKit menu windows above Plume's `.screenSaver` bubbles. Without
/// this, `NSMenu.popUp` opens at `.popUpMenu` (~101) and is invisible under
/// the chain — which looks exactly like "right-click does nothing".
private final class ChipMenuLift: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        ChipMenuLift.elevateOpenMenus()
        // Submenus / delayed presentation need another pass next turn.
        DispatchQueue.main.async { ChipMenuLift.elevateOpenMenus() }
    }

    func menuDidClose(_ menu: NSMenu) {}

    static func elevateOpenMenus() {
        let target = NSWindow.Level(rawValue: PlumeOverlay.level.rawValue + 1)
        for window in NSApp.windows {
            let lvl = window.level.rawValue
            // Default menu / submenu windows; also catch private NSMenu subclasses.
            if lvl == NSWindow.Level.popUpMenu.rawValue
                || lvl == NSWindow.Level.tornOffMenu.rawValue
                || window.className.contains("Menu") {
                window.level = target
                window.collectionBehavior = PlumeOverlay.collectionBehavior
                window.hidesOnDeactivate = false
                window.orderFrontRegardless()
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the main web view whenever the dock badge changes.
    static let plumeUnreadChanged = Notification.Name("plume.unreadChanged")
    /// Posted when Messenger's in-page photo/video theater opens or closes
    /// inside the bubble card (`userInfo["open"]` as Bool).
    static let plumeCardMedia = Notification.Name("plume.cardMedia")
    /// User tapped a conversation image while the bubble card is active —
    /// `userInfo["url"]` is a URL for the native in-card photo viewer.
    static let plumeOpenImage = Notification.Name("plume.openImage")
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

    /// A thread the chain has no head for — enough to put it in the card.
    init(thread: URL) {
        url = thread
        name = "Messenger"
        avatar = nil
        unread = false
        preview = ""
        time = ""
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

private final class TetherView: NSView {
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

// MARK: - Bubble content

/// Tuning for the bubble chain. Geometry first, then the springs.
enum Chain {
    // canvas == peak is load-bearing: the panel never resizes, so a magnified
    // circle can never be clipped, and magnification never moves a bubble —
    // which is what lets hover be measured against live positions without the
    // scale → layout → distance → scale feedback loop the real Dock must fight.
    /// Resting circle — the one number the user sets.
    static var base: CGFloat { Preferences.bubbleSize }
    /// Circle under the cursor. 2× so the hovered head clearly dominates its
    /// neighbours (Dock-strong); the neighbour weight below keeps them modest.
    static var peak: CGFloat { (base * 2.0).rounded() }
    /// Panel edge. Equal to `peak` for the life of a panel so magnification
    /// never clips — independent of how tightly the chain is packed.
    static var canvas: CGFloat { peak }
    /// Centre-to-centre at rest — nearly touching (≈4pt edge gap), independent
    /// of Dock magnification.
    static var step: CGFloat { (base + 4).rounded() }
    static let margin: CGFloat = 6         // gap to visibleFrame at rest

    /// Anchor spring — the released bubble flying to the edge.
    static let anchorOmega: CGFloat = 13
    static let anchorZeta: CGFloat = 0.9
    static let maxOvershoot: CGFloat = 10  // pt past the rest line, hard clamp

    /// Followers. τ is the lag behind the bubble in front; ω = 2ζ/τ. Ramping τ
    /// down the chain makes it unfurl instead of sliding rigidly.
    static let trailZeta: CGFloat = 0.8
    static func trailTau(_ k: Int) -> CGFloat { 0.050 + 0.008 * CGFloat(min(k, 5) - 1) }

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

    /// Unused for slot-based Dock weights; kept as the "near column" hit slop.
    static var magRadius: CGFloat { step * 1.5 }
    /// Constant visual edge gap while packing (rest and magnified).
    static var magGap: CGFloat { step - base }
    /// Centre-to-centre between two live diameters (Dock packing).
    static func linkSpacing(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (a + b) / 2 + magGap
    }

    /// X centres of a docked row: packed left-to-right, then centered on `card`.
    /// If the row is wider than the card it pins to the right inset (same as
    /// before) and is then nudged onto `visible` so a head never leaves the screen.
    static func dockedRowXs(diameters: [CGFloat], card: CGRect,
                            visible: CGRect, pad: CGFloat = 8) -> [CGFloat] {
        guard !diameters.isEmpty else { return [] }
        var xs: [CGFloat] = []
        xs.reserveCapacity(diameters.count)
        for i in diameters.indices {
            if i == 0 {
                xs.append(diameters[i] / 2)
            } else {
                xs.append(xs[i - 1] + linkSpacing(diameters[i - 1], diameters[i]))
            }
        }
        let last = xs.count - 1
        let groupWidth = xs[last] + diameters[last] / 2
        let innerLeft = card.minX + pad
        let innerRight = card.maxX - pad
        let innerWidth = innerRight - innerLeft
        var origin = card.midX - groupWidth / 2
        if groupWidth <= innerWidth {
            origin = min(max(origin, innerLeft), innerRight - groupWidth)
        } else {
            origin = innerLeft
        }
        for i in xs.indices { xs[i] += origin }

        let overflow = xs[last] + diameters[last] / 2 + pad - card.maxX
        if overflow > 0 {
            for i in xs.indices { xs[i] -= overflow }
        }
        let minAllowed = visible.minX + peak / 2 + 2
        if let first = xs.first, first < minAllowed {
            let dx = minAllowed - first
            for i in xs.indices { xs[i] += dx }
        }
        return xs
    }
    /// Fraction of (peak−base) for the adjacent slot. Low enough that the
    /// neighbour never reads as "almost as big" as the hovered head.
    static let magNeighbour: CGFloat = 0.26
    static let magNextNeighbour: CGFloat = 0.05
    /// While the card is open, the owning head stays at least this large even
    /// when the pointer is over a neighbour — so you can see which chat is live.
    static let openBoost: CGFloat = 0.62
    /// Higher = snappier hover response (settles in ~3–4 frames at 120Hz).
    static let magRate: CGFloat = 36
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
            onSecondaryClick?(convert(event.locationInWindow, from: nil))
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
        if didDrag { onDragEnded?(flickVelocity()); return }
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
    /// Right-click → "Delete Chat…". No menu at all while this is nil.
    var onDelete: ((BubbleConversation) -> Void)?
    private static let menuLift = ChipMenuLift()
    private let avatarView = NSImageView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private var highlighted = false

    init(conversation: BubbleConversation) {
        self.conversation = conversation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor

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

    override func rightMouseDown(with event: NSEvent) {
        guard onDelete != nil else { super.rightMouseDown(with: event); return }
        let menu = NSMenu()
        // The card floats at the overlay tier; a plain menu opens beneath it.
        menu.delegate = Self.menuLift
        let item = NSMenuItem(title: L.t("Xoá đoạn chat…", "Delete Chat…"),
                              action: #selector(deleteTapped), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(item)
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func deleteTapped() { onDelete?(conversation) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// List-owned hover: rows do not track enter/exit themselves. Scrolling
    /// moves rows under a still cursor without those events, which left a
    /// stale highlight ("ghost") on the wrong row.
    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        // Never assign nil — on a layer-backed view that can leave the previous
        // fill composited as a translucent smear while scrolling.
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
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
    /// Right-click → "Delete Chat…" on a row.
    var onDelete: ((BubbleConversation) -> Void)?
    /// Footer action: ask the controller for an older page of the inbox.
    var onLoadMore: (() -> Void)?
    private let stack = NSStackView()
    private let search = NSSearchField()
    private weak var scroll: NSScrollView?
    private var all: [BubbleConversation] = []
    private var hoverTracker: NSTrackingArea?
    private var canLoadMore = false
    private var loadMoreBusy = false
    private let loadMoreButton = NSButton()

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
        loadMoreButton.bezelStyle = .flexiblePush
        loadMoreButton.isBordered = true
        loadMoreButton.font = .systemFont(ofSize: 13, weight: .semibold)
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreTapped)
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        loadMoreButton.setButtonType(.momentaryPushIn)
        loadMoreButton.controlSize = .regular
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        scroll.documentView = clip
        addSubview(scroll)

        // Hover is owned here (not per-row tracking). Scrolling under a still
        // cursor never fires mouseExited on the old row; clip bounds + live
        // scroll + mouseMoved all re-resolve the lit row from the pointer.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollClipMoved),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollClipMoved),
            name: NSScrollView.didLiveScrollNotification, object: scroll)

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracker { removeTrackingArea(hoverTracker) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracker = t
    }

    override func mouseMoved(with event: NSEvent) { syncRowHighlights() }
    override func mouseEntered(with event: NSEvent) { syncRowHighlights() }
    override func mouseExited(with event: NSEvent) { clearRowHighlights() }

    func set(_ conversations: [BubbleConversation],
             canLoadMore: Bool = false,
             preserveScroll: Bool = false) {
        all = conversations
        self.canLoadMore = canLoadMore
        render(preserveScroll: preserveScroll)
    }

    func setLoadMoreBusy(_ busy: Bool) {
        loadMoreBusy = busy
        refreshLoadMoreTitle()
    }

    @objc private func filterChanged() { render(preserveScroll: true) }

    @objc private func loadMoreTapped() {
        guard canLoadMore, !loadMoreBusy else { return }
        onLoadMore?()
    }

    private func refreshLoadMoreTitle() {
        let title = loadMoreBusy
            ? L.t("Đang tải…", "Loading…")
            : L.t("Xem thêm đoạn chat…", "Load more chats…")
        loadMoreButton.title = title
        loadMoreButton.isEnabled = canLoadMore && !loadMoreBusy
        loadMoreButton.alphaValue = loadMoreBusy ? 0.55 : 1
    }

    private func render(preserveScroll: Bool = false) {
        let savedY = scroll?.contentView.bounds.origin.y ?? 0
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let filtering = !q.isEmpty
        let shown = filtering ? all.filter {
            $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        } : all
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for convo in shown {
            let row = ConversationRow(conversation: convo)
            row.onPick = { [weak self] c in self?.onPick?(c) }
            row.onDelete = { [weak self] c in self?.onDelete?(c) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Footer only on the unfiltered inbox — search already narrows `all`.
        if canLoadMore, !filtering {
            refreshLoadMoreTitle()
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(loadMoreButton)
            NSLayoutConstraint.activate([
                wrap.heightAnchor.constraint(equalToConstant: 52),
                loadMoreButton.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                loadMoreButton.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                loadMoreButton.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 16),
                loadMoreButton.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -16),
                loadMoreButton.heightAnchor.constraint(equalToConstant: 32),
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if preserveScroll {
                self.scroll?.documentView?.scroll(NSPoint(x: 0, y: savedY))
            } else {
                self.scroll?.documentView?.scroll(.zero)
            }
            if let scroll = self.scroll {
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.syncRowHighlights()
        }
    }

    @objc private func scrollClipMoved() { syncRowHighlights() }

    private func clearRowHighlights() {
        stack.arrangedSubviews
            .compactMap { $0 as? ConversationRow }
            .forEach { $0.setHighlighted(false) }
    }

    private func syncRowHighlights() {
        guard let window else { clearRowHighlights(); return }
        let winP = window.mouseLocationOutsideOfEventStream
        let clip = scroll?.contentView
        for case let row as ConversationRow in stack.arrangedSubviews {
            let p = row.convert(winP, from: nil)
            var on = row.bounds.contains(p)
            if on, let clip {
                let inClip = clip.convert(winP, from: nil)
                on = clip.bounds.contains(inClip)
                let rowInClip = row.convert(row.bounds, to: clip)
                on = on && rowInClip.intersects(clip.bounds)
            }
            row.setHighlighted(on)
        }
    }
}

// MARK: - In-card photo viewer

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Full-bleed black overlay centred in the bubble *card* (not the chrome-clipped
/// web view). Messenger's own theatre always looks left-shifted here.
private final class CardPhotoOverlay: NSView {
    var onClose: (() -> Void)?
    private let imageView = PassthroughImageView()
    private let closeButton = NSButton()
    private var loadTask: URLSessionDataTask?
    private var keyMonitor: Any?
    private var cookieSession: URLSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.close()
                return nil
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        cookieSession?.invalidateAndCancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func display(_ image: NSImage) {
        imageView.image = image
    }

    /// Load via a URLSession seeded with the web view's cookies so fbcdn
    /// auth'd assets resolve the same way the page does.
    func load(url: URL, cookieStore: WKHTTPCookieStore) {
        loadTask?.cancel()
        cookieSession?.invalidateAndCancel()
        if let cached = AvatarCache.image(for: url) {
            imageView.image = cached
            return
        }
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let jar = HTTPCookieStorage()
            for cookie in cookies {
                jar.setCookie(cookie)
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = jar
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .always
            let session = URLSession(configuration: config)
            self.cookieSession = session
            let task = session.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    AvatarCache.store(image, for: url)
                    self?.imageView.image = image
                }
            }
            self.loadTask = task
            task.resume()
        }
    }

    override func mouseDown(with event: NSEvent) {
        close()
    }

    @objc private func close() { onClose?() }
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
    private let tether = BubbleTetherPanel()
    private var bubbles: [BubblePanel] = []
    private var webView: WKWebView!
    private var isExpanded = false
    private var currentThread: URL?
    private var showingPicker = false
    /// Index of the bubble the card belongs to, for the fold-away animation.
    private var lastOpenedIndex = 0
    private var collapseWork: DispatchWorkItem?
    /// True while a system file/photo picker sheet is up — resignKey must not
    /// fold the card mid-attach.
    private var attachmentPickerActive = false
    private let listView = ConversationListView(frame: .zero)
    /// Supplied by the owner: the main web view still holds the live list.
    var fetchConversations: ((Int, @escaping ([BubbleConversation]) -> Void) -> Void)?
    /// Confirm with the user, then delete the whole conversation on Messenger.
    /// Calls back with true only when it is really gone.
    var deleteConversation: ((BubbleConversation, @escaping (Bool) -> Void) -> Void)?
    /// How many inbox rows the picker currently asks Messenger for.
    private var pickerLimit = 24
    private var lastPickerCount = 0
    private var pickerStalls = 0
    private static let pickerPage = 24
    private static let pickerMax = 200
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
            self, selector: #selector(cardMediaChanged(_:)),
            name: .plumeCardMedia, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openImageRequested(_:)),
            name: .plumeOpenImage, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Fullscreen Spaces can demote join-all-spaces panels on entry; re-pin.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
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
        panel.level = PlumeOverlay.level
        PlumeOverlay.apply(to: panel)
        panel.orderFrontRegardless()
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
        promoteOverlayStack()
        wake()
    }

    @objc private func activeSpaceChanged() {
        // Entering another app's fullscreen Space can leave join-all panels on
        // the desktop Space behind it until they are ordered front again.
        promoteOverlayStack()
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
    /// Also reshuffles / refreshes the chain so newest Messenger threads sit
    /// nearest the app chip.
    private func refreshUnreadFlags() {
        fetchConversations?(max(Preferences.bubbleLimit * 3, 12)) { [weak self] convos in
            guard let self else { return }
            let contacts = max(0, self.bubbles.count - 1)
            let inboxHidden = self.isExpanded && !self.showingPicker
            guard BubbleChainSync.shouldApplySnapshot(
                count: convos.count, contactHeads: contacts, inboxHidden: inboxHidden)
            else { return }
            let unread = Set(convos.filter(\.unread).map(\.url))
            for panel in self.bubbles {
                guard let chip = self.chip(panel), let convo = chip.conversation else { continue }
                chip.setBadge(unread.contains(convo.url) ? "" : nil)
            }
            self.syncChainToRecents(convos)
        }
    }

    private func conversation(of panel: BubblePanel) -> BubbleConversation? {
        (panel.contentView as? BubbleChipView)?.conversation
    }

    /// Match the contact chain to Messenger's newest-first list. Index 0 (app
    /// chip) never moves. Skipped mid-drag so the gesture keeps its grab.
    private func syncChainToRecents(_ convos: [BubbleConversation]) {
        guard !dragging, !bubbles.isEmpty else { return }
        let contacts = max(0, bubbles.count - 1)
        let inboxHidden = isExpanded && !showingPicker
        guard BubbleChainSync.shouldApplySnapshot(
            count: convos.count, contactHeads: contacts, inboxHidden: inboxHidden)
        else { return }
        let want = Array(convos.prefix(Preferences.bubbleLimit))
        let wantURLs = want.map(\.url)

        // Drop contact heads that fell out of the recent window.
        for i in stride(from: bubbles.count - 1, through: 1, by: -1) {
            guard let u = conversation(of: bubbles[i])?.url else { continue }
            if !wantURLs.contains(u) {
                adjustIndicesAfterRemoval(i)
                removeBubble(at: i)
            }
        }

        // Ensure each recent exists, then move it to its rank (1 = newest).
        for (rank, convo) in want.enumerated() {
            let target = rank + 1
            if let existing = bubbles.firstIndex(where: { conversation(of: $0)?.url == convo.url }) {
                if existing != target { moveBubble(from: existing, to: target) }
            } else {
                while bubbles.count - 1 >= Preferences.bubbleLimit, bubbles.count > 1 {
                    let last = bubbles.count - 1
                    adjustIndicesAfterRemoval(last)
                    removeBubble(at: last)
                }
                let insertAt = min(target, bubbles.count)
                let centre = centres.indices.contains(min(insertAt, max(0, centres.count - 1)))
                    ? centres[min(insertAt, centres.count - 1)]
                    : (centres.first ?? savedHeadCentre())
                appendBubble(convo, centre: centre, at: insertAt)
                if anchorIndex >= insertAt { anchorIndex += 1 }
                if lastOpenedIndex >= insertAt { lastOpenedIndex += 1 }
                if let focus = hoverFocus, focus >= insertAt { hoverFocus = focus + 1 }
            }
        }

        // Final pass: order must match `want` exactly.
        for (rank, convo) in want.enumerated() {
            let target = rank + 1
            guard let existing = bubbles.firstIndex(where: { conversation(of: $0)?.url == convo.url }),
                  existing != target else { continue }
            moveBubble(from: existing, to: target)
        }
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        wake()
    }

    private func adjustIndicesAfterRemoval(_ i: Int) {
        if lastOpenedIndex == i { lastOpenedIndex = 0 }
        else if lastOpenedIndex > i { lastOpenedIndex -= 1 }
        if anchorIndex == i { anchorIndex = 0 }
        else if anchorIndex > i { anchorIndex -= 1 }
        if let focus = hoverFocus {
            if focus == i { hoverFocus = nil }
            else if focus > i { hoverFocus = focus - 1 }
        }
    }

    /// Reorder one head and every parallel array that tracks it.
    private func moveBubble(from: Int, to: Int) {
        guard from != to,
              bubbles.indices.contains(from),
              (0..<bubbles.count).contains(to) else { return }
        func move<T>(_ a: inout [T], from: Int, to: Int) {
            let x = a.remove(at: from)
            a.insert(x, at: to > from ? to - 1 : to)
        }
        move(&bubbles, from: from, to: to)
        move(&centres, from: from, to: to)
        move(&velocities, from: from, to: to)
        move(&diameters, from: from, to: to)
        move(&hoverTargets, from: from, to: to)
        move(&born, from: from, to: to)

        func mapIndex(_ i: Int) -> Int {
            if i == from { return to > from ? to - 1 : to }
            if from < to {
                if i > from && i <= to { return i - 1 }
            } else {
                if i >= to && i < from { return i + 1 }
            }
            return i
        }
        lastOpenedIndex = mapIndex(lastOpenedIndex)
        anchorIndex = mapIndex(anchorIndex)
        if let focus = hoverFocus { hoverFocus = mapIndex(focus) }
    }

    /// Picking from the app chip's list earns that contact its own head, the way
    /// tapping a chat on Android spawns a bubble. The oldest contact head falls
    /// off once the chain hits the user's limit.
    private func spawnBubble(for convo: BubbleConversation) {
        if let existing = bubbles.firstIndex(where: { conversation(of: $0)?.url == convo.url }) {
            // Already open as a head — promote to newest slot.
            if existing != 1 { moveBubble(from: existing, to: 1) }
            return
        }
        // index 0 is the app chip; contacts follow it.
        if bubbles.count - 1 >= Preferences.bubbleLimit, bubbles.count > 1 {
            adjustIndicesAfterRemoval(bubbles.count - 1)
            removeBubble(at: bubbles.count - 1)
        }
        let centre = centres.first.map { NSPoint(x: $0.x, y: $0.y - Chain.step) } ?? savedHeadCentre()
        appendBubble(convo, centre: centre, at: 1)
        if anchorIndex >= 1 { anchorIndex += 1 }
        if lastOpenedIndex >= 1 { lastOpenedIndex += 1 }
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
            view.wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
            let lead = view.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                     constant: m)
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
            // Layout no longer shifts the web view; chrome is CSS-hidden.
            if !self.theaterMode { self.pushCardClip() }
        }
    }

    /// When Messenger's photo theatre opens, expand the card to nearly fill the
    /// display and temporarily unclip the sidebar — theatre centres on the full
    /// page, so only a wide unclipped window lays it out correctly.
    private var theaterMode = false
    private var preTheaterSize: NSSize?
    /// Debounce theatre open/close so a one-frame DOM blip cannot thrash size.
    private var theaterOpenTicks = 0
    private var theaterCloseTicks = 0
    /// After we expand for a tap, theatre has not mounted yet — do not restore
    /// the small card until this deadline (or until theatre is seen, then lost).
    private var theaterHoldUntil: CFTimeInterval = 0
    private var photoOverlay: CardPhotoOverlay?
    private var mediaCenterTimer: Timer?
    private var overlayPromoteWork: [DispatchWorkItem] = []

    private func pushCardClip(_ override: CGFloat? = nil) {
        guard webView != nil else { return }
        clearTheaterOptics()
        let active = isExpanded && !showingPicker
            && webView.superview === card.contentView
        sidebarConstraint?.constant = Self.inset
        _ = override
        let cssJSON = Self.jsonString(InjectedScript.cardThreadCSS) ?? "\"\""
        let js = """
        window.__plumeCardActive=\(active ? "true" : "false");
        window.__plumeCardClip=0;
        window.__plumeTheaterMode=\(theaterMode ? "true" : "false");
        try {
          document.documentElement.classList.toggle("plume-card-thread", \(active ? "true" : "false"));
        } catch (e) {}
        if (\(active ? "true" : "false")) {
          window.__plumeSetStyle && window.__plumeSetStyle("\(InjectedScript.StyleID.cardThread)", \(cssJSON));
        } else {
          window.__plumeRemoveStyle && window.__plumeRemoveStyle("\(InjectedScript.StyleID.cardThread)");
        }
        window.__plumeClearCardOverlays && window.__plumeClearCardOverlays();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        if active {
            startOverlayFitTimer()
        } else {
            stopOverlayFitTimer()
            exitTheaterMode(restore: false)
            hidePhotoOverlay()
        }
    }

    private func clearTheaterOptics() {
        guard webView != nil else { return }
        webView.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        webView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Poll theatre open/close; reinforce overlay-fit only while clipped.
    private func startOverlayFitTimer() {
        guard mediaCenterTimer == nil else { return }
        let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self, self.isExpanded, !self.showingPicker else { return }
            self.pollTheaterMode()
            if !self.theaterMode {
                self.webView.evaluateJavaScript(
                    "window.__plumeFitCardOverlays&&window.__plumeFitCardOverlays()",
                    completionHandler: nil)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        mediaCenterTimer = t
    }

    private func stopOverlayFitTimer() {
        mediaCenterTimer?.invalidate()
        mediaCenterTimer = nil
    }

    private func startMediaCenterTimer() { startOverlayFitTimer() }
    private func stopMediaCenterTimer() { stopOverlayFitTimer() }
    private func reinforceMediaCenter() {
        pollTheaterMode()
    }

    private func pollTheaterMode() {
        webView.evaluateJavaScript(
            "window.__plumeDetectTheater&&window.__plumeDetectTheater()"
        ) { [weak self] result, _ in
            guard let self, self.isExpanded, !self.showingPicker else { return }
            let open = (result as? Bool) == true
            if open {
                self.theaterCloseTicks = 0
                self.theaterHoldUntil = 0
                self.theaterOpenTicks += 1
                // Two ticks (~0.44s): a one-frame emoji/reaction dialog must
                // not expand the card. Photo theatre stays open well past that.
                if self.theaterOpenTicks >= 2 { self.enterTheaterMode() }
            } else {
                self.theaterOpenTicks = 0
                if CACurrentMediaTime() < self.theaterHoldUntil { return }
                self.theaterCloseTicks += 1
                if self.theaterCloseTicks >= 3 { self.exitTheaterMode(restore: true) }
            }
        }
    }

    private func enterTheaterMode() {
        if theaterMode {
            theaterHoldUntil = max(theaterHoldUntil, CACurrentMediaTime() + 0.8)
            return
        }
        guard isExpanded, !showingPicker else { return }
        theaterMode = true
        theaterOpenTicks = 2
        theaterCloseTicks = 0
        theaterHoldUntil = CACurrentMediaTime() + 2.0
        preTheaterSize = card.contentRect(forFrameRect: card.frame).size

        // Unclip: give Messenger the full page so theatre centres in the card.
        sidebarConstraint?.constant = Self.inset
        pushCardClip(0)

        let visible = hostScreen.visibleFrame
        let lane = Chain.peak + 12
        let pad: CGFloat = 10
        let size = NSSize(
            width: max(card.minSize.width, visible.width - pad * 2),
            height: max(card.minSize.height, visible.height - lane - pad))
        card.setContentSize(size)
        let frameSize = card.frame.size
        let origin = NSPoint(
            x: (visible.minX + (visible.width - frameSize.width) / 2).rounded(),
            y: (visible.maxY - lane - frameSize.height).rounded())
        card.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        PlumeOverlay.apply(to: card)
        card.orderFrontRegardless()
        promoteOverlayStack()
        wake()
        // Replay is optional; theatre should already open in this viewport.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.theaterMode else { return }
            self.webView.evaluateJavaScript(
                "window.__plumeReplayArmedImage&&window.__plumeReplayArmedImage()",
                completionHandler: nil)
        }
    }

    private func exitTheaterMode(restore: Bool) {
        guard theaterMode else { return }
        theaterMode = false
        theaterOpenTicks = 0
        theaterCloseTicks = 0
        theaterHoldUntil = 0
        if restore, let saved = preTheaterSize {
            let visible = hostScreen.visibleFrame
            let lane = Chain.peak + 10
            let size = NSSize(
                width: min(max(saved.width, card.minSize.width), visible.width - 16),
                height: min(max(saved.height, card.minSize.height), visible.height - lane))
            card.setContentSize(size)
        }
        preTheaterSize = nil
        sidebarConstraint?.constant = Self.inset
        pushCardClip(0)
        if restore, isExpanded, card.isVisible {
            positionCard()
            promoteOverlayStack()
            wake()
        }
    }

    @objc private func cardMediaChanged(_ note: Notification) {
        let open = (note.userInfo?["open"] as? Bool) ?? false
        if open { enterTheaterMode() }
        else { exitTheaterMode(restore: true) }
    }

    @objc private func openImageRequested(_ note: Notification) {
        guard isExpanded, !showingPicker else { return }
        enterTheaterMode()
    }

    private func showPhotoOverlay(url: URL) {
        _ = url
    }

    private func hidePhotoOverlay() {
        photoOverlay?.removeFromSuperview()
        photoOverlay = nil
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
        // Bubbles sit at `.screenSaver`; AppKit's default menu window is only
        // `.popUpMenu` (~101) and opens *under* the chain — looks like right-
        // click does nothing. Elevate tracking menus to our overlay tier.
        menu.delegate = chipMenuLift

        let back = NSMenuItem(title: L.t("Về cửa sổ chính", "Back to the Main Window"),
                              action: #selector(exitBubbleMode), keyEquivalent: "")
        back.target = self
        back.image = Self.menuSymbol("macwindow")
        menu.addItem(back)
        menu.addItem(.separator())

        let limits = NSMenu()
        limits.delegate = chipMenuLift
        for n in [3, 5, 8, 12] {
            let item = NSMenuItem(title: "\(n)", action: #selector(pickLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = n
            item.state = Preferences.bubbleLimit == n ? .on : .off
            limits.addItem(item)
        }
        let limitItem = NSMenuItem(title: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                   action: nil, keyEquivalent: "")
        limitItem.image = Self.menuSymbol("circle.grid.2x2")
        limitItem.submenu = limits
        menu.addItem(limitItem)

        let sizes = NSMenu()
        sizes.delegate = chipMenuLift
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
        sizeItem.image = Self.menuSymbol("circle.fill")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let display = NSMenu()
        display.delegate = chipMenuLift
        let follow = NSMenuItem(
            title: L.t("Theo màn hình đang hoạt động", "Follow active display"),
            action: #selector(pickFollowDisplay(_:)), keyEquivalent: "")
        follow.target = self
        follow.tag = 1
        follow.state = Preferences.bubbleFollowActiveDisplay ? .on : .off
        follow.image = Self.menuSymbol("arrow.triangle.2.circlepath")
        display.addItem(follow)
        let stay = NSMenuItem(
            title: L.t("Giữ nguyên màn hình hiện tại", "Stay on current display"),
            action: #selector(pickFollowDisplay(_:)), keyEquivalent: "")
        stay.target = self
        stay.tag = 0
        stay.state = Preferences.bubbleFollowActiveDisplay ? .off : .on
        stay.image = Self.menuSymbol("pin")
        display.addItem(stay)
        let displayItem = NSMenuItem(
            title: L.t("Vị trí màn hình", "Display placement"),
            action: nil, keyEquivalent: "")
        displayItem.image = Self.menuSymbol("display")
        displayItem.submenu = display
        menu.addItem(displayItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L.t("Thoát Plume", "Quit Plume"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.image = Self.menuSymbol("power")
        menu.addItem(quit)

        // Anchor in a tiny panel at our overlay level so the menu is parented
        // into the same Space / tier as the bubbles (not the desktop Space).
        let mouse = NSEvent.mouseLocation
        let anchor = chipMenuAnchor
        PlumeOverlay.apply(to: anchor)
        anchor.setFrame(NSRect(x: mouse.x, y: mouse.y - 1, width: 2, height: 2),
                        display: false)
        anchor.orderFrontRegardless()
        ChipMenuLift.elevateOpenMenus()
        menu.popUp(positioning: nil, at: NSPoint(x: 1, y: 1), in: anchor.contentView)
        anchor.orderOut(nil)
    }

    /// Retained so NSMenu.delegate stays alive for the popUp duration.
    private let chipMenuLift = ChipMenuLift()
    /// 1×1 host for context menus — must outlive a single popUp call.
    private lazy var chipMenuAnchor: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.level = PlumeOverlay.level
        PlumeOverlay.apply(to: p)
        p.contentView = NSView(frame: p.contentRect(forFrameRect: p.frame))
        return p
    }()

    /// Template SF Symbol sized for context menus.
    private static func menuSymbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let sized = image.withSymbolConfiguration(config) ?? image
        sized.isTemplate = true
        return sized
    }

    /// App-chip context menu from a screen-space click (monitor path).
    private var chipMenuShownAt: CFTimeInterval = 0
    private func showAppChipMenu(atScreenPoint point: NSPoint) {
        guard let panel = bubbles.first, let chip = chip(panel) else { return }
        // Local + global monitors both see the same click — open once.
        let now = CACurrentMediaTime()
        if now - chipMenuShownAt < 0.35 { return }
        chipMenuShownAt = now
        // Cancel any pending auto-collapse so resignKey from the menu host
        // cannot fold the card while the user is picking.
        collapseWork?.cancel(); collapseWork = nil
        showChipMenu(from: chip, at: chip.convert(
            panel.convertFromScreen(NSRect(origin: point, size: .zero)).origin,
            from: nil))
    }

    /// True when `screenPoint` lands on the app chip's visible circle.
    private func isAppChipHit(atScreenPoint screenPoint: NSPoint) -> Bool {
        guard let panel = bubbles.first else { return false }
        // Prefer the live panel frame — `centres` can lag a commit behind.
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let live = diameters.indices.contains(0) ? diameters[0] : Chain.base
        let r = max(live, Chain.base) / 2 + 6
        return hypot(screenPoint.x - c.x, screenPoint.y - c.y) <= r
    }

    @objc private func pickFollowDisplay(_ sender: NSMenuItem) {
        Preferences.bubbleFollowActiveDisplay = sender.tag == 1
        foreignScreenTicks = 0
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
    private func open(_ convo: BubbleConversation?, toggle: Bool = true) {
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
        if toggle, isExpanded, card.isVisible,
           (convo == nil && showingPicker) || (convo != nil && convo?.url == live) {
            collapse(); return
        }
        if let convo {
            // Promote the opened head to the newest contact slot.
            if let i = bubbles.firstIndex(where: { conversation(of: $0)?.url == convo.url }), i != 1 {
                moveBubble(from: i, to: 1)
                lastOpenedIndex = 1
            }
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
        // Open-boost layout before the first docked frame, then land on packed
        // row slots immediately — otherwise every head piles onto rest-step X
        // while diameters are still animating and the row looks stacked.
        applyHoverFromFocus()
        if centres.count == bubbles.count {
            centres = rowSlots()
            for i in velocities.indices { velocities[i] = .zero }
        }
        wake()
        // A short fade, deliberately not a frame animation: growing a window
        // that holds a live WKWebView re-lays-out the page on every frame, so
        // the "nice" opening animation is the slow one.
        card.contentView?.layer?.removeAnimation(forKey: "plume.fold")
        card.contentView?.layer?.transform = CATransform3DIdentity
        card.alphaValue = 0
        // Same path as the bubbles: orderFrontRegardless pins the card above
        // fullscreen apps on the target display. Do NOT NSApp.activate — that
        // pulls Plume's Space forward and leaves the card behind Claude/etc.
        // makeKey alone is enough for the composer thanks to nonactivatingPanel.
        promoteOverlayStack()
        card.makeKey()
        // makeKey / Space transitions can demote the card for a beat — re-pin
        // after the run loop and again once Mission Control settles.
        overlayPromoteWork.forEach { $0.cancel() }
        overlayPromoteWork.removeAll()
        for delay in [0.0, 0.05, 0.2, 0.5, 1.0, 2.0] as [TimeInterval] {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isExpanded else { return }
                self.promoteOverlayStack()
            }
            overlayPromoteWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
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
        // Newest-first order may have changed while the chain was idle.
        refreshUnreadFlags()
    }

    /// A native notification was clicked. `activate` replays the click in the
    /// page, which routes Messenger to that conversation; the card then opens
    /// on wherever the page landed — never the main window, never NSApp.activate.
    func openFromNotification(_ activate: (@escaping (Bool) -> Void) -> Void) {
        let before = ThreadURL.canonical(from: webView.url)
        activate { [weak self] known in
            guard let self else { return }
            guard known else {
                // The page has forgotten it (reloaded since): offer the list.
                if !(self.isExpanded && self.showingPicker) {
                    self.lastOpenedIndex = 0
                    self.open(nil)
                }
                return
            }
            self.awaitNotificationThread(from: before, tries: 8)
        }
    }

    /// Messenger routes asynchronously after the click; wait for the address
    /// to move, and settle for where it already is when it doesn't (the
    /// notification was for the conversation the page had open).
    private func awaitNotificationThread(from before: URL?, tries: Int) {
        let now = ThreadURL.canonical(from: webView.url)
        if tries > 0, now == nil || now == before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.awaitNotificationThread(from: before, tries: tries - 1)
            }
            return
        }
        guard !bubbles.isEmpty else { return }
        guard let thread = now else {
            if !(isExpanded && showingPicker) { lastOpenedIndex = 0; open(nil) }
            return
        }
        // Already showing it: `open` would read that as "same bubble twice"
        // and fold the card away.
        if isExpanded, card.isVisible, !showingPicker {
            currentThread = thread
            if let i = bubbles.firstIndex(where: { conversation(of: $0)?.url == thread }) {
                lastOpenedIndex = i
                wake()
            }
            promoteOverlayStack()
            card.makeKey()
            return
        }
        if let i = bubbles.firstIndex(where: { conversation(of: $0)?.url == thread }),
           let convo = conversation(of: bubbles[i]) {
            lastOpenedIndex = i
            open(convo, toggle: false)
        } else {
            lastOpenedIndex = 0
            open(BubbleConversation(thread: thread), toggle: false)
        }
    }

    /// Pin card + heads above fullscreen app content. Bubbles stay above the
    /// card so the docked row remains clickable.
    private func promoteOverlayStack() {
        PlumeOverlay.apply(to: card)
        PlumeOverlay.apply(to: tether)
        for panel in bubbles {
            PlumeOverlay.apply(to: panel)
        }
        // Card first, then tether, then bubbles — same overlay tier, stable
        // stacking so the heads stay clickable above the chat window.
        if card.isVisible || isExpanded {
            card.orderFrontRegardless()
        }
        if tether.isVisible {
            tether.orderFrontRegardless()
        }
        for panel in bubbles where panel.isVisible {
            panel.orderFrontRegardless()
        }
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
        pushCardClip()
    }

    private func showThread(_ url: URL) {
        showingPicker = false
        applyThreadSize()
        if card.isVisible { keepCardOnScreen() }
        installContent(webView)
        currentThread = url
        scheduleCardFixups()

        let alreadyOpen = ThreadURL.canonical(from: webView.url) == url
        // Patch helpers onto the live page first — user scripts only run at
        // document start, so an already-open Messenger session would keep the
        // old "same URL ⇒ no-op" behaviour otherwise.
        // Click the inbox row *before* hiding it: CSS-hiding navigation first
        // made `__plumeOpenThread` miss the link and fall through to a full
        // reload, which emptied the recents DOM and wiped the bubble chain.
        webView.evaluateJavaScript(InjectedScript.threadRefreshHelpers) { [weak self] _, _ in
            guard let self else { return }
            self.openThreadInPage(url, force: alreadyOpen)
            self.pushCardClip()
        }
    }

    private func openThreadInPage(_ url: URL, force: Bool) {
        if let live = webView.url, Plume.isInternal(live),
           let hrefJSON = Self.jsonString(url.absoluteString) {
            webView.evaluateJavaScript("window.__plumeOpenThread(\(hrefJSON), \(force ? "true" : "false"))") {
                [weak self] _, _ in
                // Never `load()` a thread URL on top of a live Messenger
                // session: a document reload tears down the inbox and the
                // next recents snapshot deletes every contact bubble.
                self?.scheduleScrollToLatest()
            }
        } else {
            webView.load(URLRequest(url: url))
            scheduleScrollToLatest()
        }
    }

    /// Ladder of scroll-to-end attempts: Messenger mounts virtualised rows
    /// asynchronously after a resize / thread re-click.
    private func scheduleScrollToLatest() {
        for delay in [0.05, 0.2, 0.45, 0.9, 1.6, 2.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isExpanded, !self.showingPicker else { return }
                self.scrollToLatest()
            }
        }
    }

    /// The app chip opens our own list — Messenger's inbox URL immediately
    /// redirects into the most recent conversation, so its list can't be shown.
    private func showPicker() {
        currentThread = nil
        showingPicker = true
        pushCardClip(0)
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
        listView.onLoadMore = { [weak self] in self?.loadMorePicker() }
        listView.onDelete = { [weak self] convo in
            self?.deleteConversation?(convo) { [weak self] deleted in
                guard let self, deleted else { return }
                // Its head goes too; index 0 is the app chip and never does.
                if let i = self.bubbles.firstIndex(where: {
                    self.conversation(of: $0)?.url == convo.url
                }), i > 0 {
                    self.adjustIndicesAfterRemoval(i)
                    self.removeBubble(at: i)
                    self.wake()
                }
                if self.showingPicker {
                    self.refreshPicker(preserveScroll: true, expandFirst: false)
                }
            }
        }
        installContent(listView)
        pickerLimit = max(Preferences.bubbleLimit * 3, Self.pickerPage)
        lastPickerCount = 0
        pickerStalls = 0
        refreshPicker(preserveScroll: false, expandFirst: false)
    }

    /// Pull a fresh inbox snapshot into the picker. Optionally scroll Messenger's
    /// virtualised list first so older threads exist in the DOM.
    private func refreshPicker(preserveScroll: Bool, expandFirst: Bool) {
        listView.setLoadMoreBusy(true)
        let finish: (Bool) -> Void = { [weak self] scrolled in
            guard let self else { return }
            let want = self.pickerLimit
            self.fetchConversations?(want) { [weak self] convos in
                guard let self else { return }
                let grew = convos.count > self.lastPickerCount
                if grew { self.pickerStalls = 0 }
                else if expandFirst { self.pickerStalls += 1 }
                self.lastPickerCount = convos.count
                // Always offer "load more" until two expands in a row add nothing.
                // (DOM usually has fewer than `want` until the inbox is scrolled.)
                let canMore = want < Self.pickerMax && self.pickerStalls < 2
                self.listView.set(convos, canLoadMore: canMore, preserveScroll: preserveScroll)
                self.listView.setLoadMoreBusy(false)
            }
        }
        guard expandFirst else { finish(false); return }
        webView.evaluateJavaScript("window.__plumeExpandConvList && window.__plumeExpandConvList()") { result, _ in
            let scrolled = (result as? Bool) == true
            // Give React a beat to mount the newly revealed rows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { finish(scrolled) }
        }
    }

    private func loadMorePicker() {
        guard pickerLimit < Self.pickerMax else {
            listView.setLoadMoreBusy(false)
            return
        }
        pickerLimit = min(pickerLimit + Self.pickerPage, Self.pickerMax)
        refreshPicker(preserveScroll: true, expandFirst: true)
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
        stopMediaCenterTimer()
        if theaterMode { exitTheaterMode(restore: true) }
        isExpanded = false
        docked = false
        hoverFocus = nil
        pushCardClip(0)
        hidePhotoOverlay()
        tether.hide()
        wake()                              // the chain flies home to its column
        bubbles.forEach { $0.orderFrontRegardless() }
        refreshUnreadFlags()

        // Folding the native conversation list into the app chip leaves a
        // translucent mini-list "ghost" on the bubble. Drop the picker before
        // any transform and skip the content-layer fold for that path.
        let foldingPicker = showingPicker
        if foldingPicker {
            listView.removeFromSuperview()
            showingPicker = false
        }

        let duration = 0.13
        if !foldingPicker, let layer = card.contentView?.layer {
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
            self.listView.removeFromSuperview()
            self.showingPicker = false
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        unreadWork?.cancel(); unreadWork = nil
        stopMediaCenterTimer()
        hidePhotoOverlay()
        docked = false
        hoverFocus = nil
        tether.hide()
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
        guard Preferences.bubbleFollowActiveDisplay else {
            PlumeTrace.log("  adopt: BỎ QUA (giữ màn hình hiện tại)")
            return
        }
        guard centres.first != nil else {
            PlumeTrace.log("  adopt: BỎ QUA (không có head)")
            return
        }
        // Same picker as everywhere else: `frame.contains` excludes the max
        // edge and falls through the dead zones between mismatched heights.
        let target = screen(nearest: NSEvent.mouseLocation)
        teleportChain(to: target, reason: "adopt")
    }

    /// Instantly re-park the whole chain onto `target` on a vertical edge.
    /// Side-by-side displays land on the shared seam; height is preserved.
    /// Springing across the gap between monitors reads as a glitch, not motion.
    @discardableResult
    private func teleportChain(to target: NSScreen, reason: String) -> Bool {
        guard let head = centres.first else { return false }
        let current = screen(nearest: head)
        PlumeTrace.log("  teleport(\(reason)): from=\(PlumeTrace.r(current.frame)) to=\(PlumeTrace.r(target.frame)) giống nhau=\(target === current)")
        guard target !== current else { return false }

        let old = current.visibleFrame, new = target.visibleFrame
        let half = Chain.canvas / 2
        let preferRight = DisplayHop.preferRightEdge(
            from: current.frame, to: target.frame, headX: head.x,
            half: half, margin: Chain.margin)
        let edgeX = DisplayHop.edgeX(preferRight: preferRight, visible: new,
                                     half: half, margin: Chain.margin)
        let fy = old.height > 0 ? (head.y - old.minY) / old.height : 0.5
        anchorIndex = 0
        anchorTarget = clampedAnchor(NSPoint(x: edgeX,
                                             y: new.minY + fy * new.height))
        PlumeTrace.log("  teleport edge=\(preferRight ? "right" : "left") target=\(PlumeTrace.p(anchorTarget))")
        for i in centres.indices {
            centres[i] = NSPoint(x: anchorTarget.x,
                                 y: anchorTarget.y - CGFloat(i) * Chain.step)
            velocities[i] = .zero
        }
        commit()
        saveAnchor()
        return true
    }

    private func positionCard(promote: Bool = true) {
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
        let lane = Chain.peak + 8          // docked row sits just above the card
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
        // Whole points: sub-pixel setFrame while the head springs made the card
        // (and the docked row that hangs off it) shimmer every frame.
        origin.x = origin.x.rounded()
        origin.y = origin.y.rounded()
        let dest = NSRect(origin: origin, size: size)
        let destScreen = screen(nearest: NSPoint(x: dest.midX, y: dest.midY))
        PlumeTrace.log("  positionCard want=\(PlumeTrace.r(dest)) visible=\(PlumeTrace.r(visible)) destScreen=\(PlumeTrace.r(destScreen.frame))")
        // orderOut first when hopping displays: even with constrainFrameRect
        // overridden, a visible panel can keep its old screen association for
        // one turn and paint on the wrong monitor.
        //
        // The hop owns both halves of that. Ordering out resigns key, which
        // reads as "clicked away" and folded the card 0.6s after it arrived;
        // and leaving the re-show to callers lost the card for good whenever
        // their own idea of "the display changed" disagreed with this one.
        let hop = card.isVisible && card.screen != nil && card.screen !== destScreen
        let wasKey = card.isKeyWindow
        if hop {
            relocatingCard = true
            card.orderOut(nil)
        }
        let dx = abs(card.frame.origin.x - dest.origin.x)
        let dy = abs(card.frame.origin.y - dest.origin.y)
        if dx > 0.5 || dy > 0.5 || card.frame.size != dest.size {
            card.setFrame(dest, display: false)
        }
        PlumeOverlay.apply(to: card)
        if hop {
            card.orderFrontRegardless()
            if wasKey { card.makeKey() }
            relocatingCard = false
        } else if promote, card.isVisible {
            card.orderFrontRegardless()
        }
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
        let lane = Chain.peak + 8
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8),
                       visible.maxY - size.height - lane)
        origin.x = origin.x.rounded()
        origin.y = origin.y.rounded()
        guard abs(origin.x - card.frame.origin.x) > 0.5
                || abs(origin.y - card.frame.origin.y) > 0.5 else { return }
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

    /// Host for system sheets (file / photo attach). Nil when the card is down.
    var sheetHost: NSWindow? { isExpanded ? card : nil }

    /// Call around `NSOpenPanel` so resignKey from the sheet does not fold the card.
    func noteAttachmentPicker(active: Bool) {
        attachmentPickerActive = active
        if active {
            collapseWork?.cancel(); collapseWork = nil
            return
        }
        guard isExpanded else { return }
        promoteOverlayStack()
        card.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isExpanded else { return }
        // Dragging a docked head undocks the card but keeps it visible; collapsing
        // here would fold the chat mid-gesture while cardTravelsWithChain is set.
        guard !dragging, !cardTravelsWithChain, !relocatingCard else { return }
        // File/photo attach sheet steals key — do not treat that as "click away".
        guard !attachmentPickerActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded, !self.card.isKeyWindow else { return }
            guard !self.dragging, !self.cardTravelsWithChain else { return }
            guard !self.attachmentPickerActive else { return }
            self.collapse()
        }
        collapseWork?.cancel()
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        collapseWork?.cancel(); collapseWork = nil
        // Becoming key can demote a nonactivating panel relative to fullscreen
        // peers — re-assert the same overlay stack the bubbles already keep.
        if isExpanded { promoteOverlayStack() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }

    /// Keep whatever size the user settles on — a chat card is personal, and
    /// re-imposing our default on every open would be a nuisance.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !showingPicker else { return }   // the picker has a size of its own
        guard !theaterMode else { return }     // ephemeral theatre size is not sticky
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
        let lane = Chain.peak + 10          // the docked row has to fit above it
        // Messenger drops the conversation from the DOM below ~900px (Caprine
        // #1718). The bubble card must be at least that wide so theatre/forward
        // overlays centre on the same viewport the user sees.
        let messengerFloor: CGFloat = 920
        size.width = min(max(size.width, messengerFloor, card.minSize.width), visible.width - 16)
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
    /// Card stays on-screen and hops with the avatar chain during a drag that
    /// started while docked — instead of orderOut'ing and leaving the chat behind.
    private var cardTravelsWithChain = false
    private var lastCardTravelScreen: NSScreen?
    /// True while `positionCard` has the card ordered out to move it between
    /// displays — that resignKey is ours, not the user clicking away.
    private var relocatingCard = false
    /// Sticky Dock focus — only changes on real pointer motion, with hysteresis,
    /// so packing/spring motion of `centres` cannot flip the zoom every frame.
    private var hoverFocus: Int?
    private var lastHoverMouse: NSPoint?

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
    /// While the card is open, occasionally re-assert overlay stacking — fullscreen
    /// peers can demote the titled card without touching the borderless bubbles.
    private var overlayKeepAliveTicks = 0

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
        // Only re-pick when the pointer actually moved. Re-sampling every poll
        // against packing centres flipped focus under a still cursor.
        let moved = lastHoverMouse.map {
            hypot(p.x - $0.x, p.y - $0.y) >= 0.5
        } ?? true
        if moved {
            let before = hoverTargets
            recomputeHoverTargets()
            syncBubbleClickThrough()
            if before != hoverTargets { wake() }
        } else {
            syncBubbleClickThrough()
        }
        followCursorScreenIfNeeded()
        if isExpanded, card.isVisible {
            overlayKeepAliveTicks += 1
            if overlayKeepAliveTicks >= 90 {   // ~3s at 30 Hz
                overlayKeepAliveTicks = 0
                promoteOverlayStack()
            }
        } else {
            overlayKeepAliveTicks = 0
        }
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
        if docked, card.isVisible { updateTether() }
        // Card rides the chain for the whole drag. Skip orderFrontRegardless on
        // the steady path — promoting every frame was measurable jank; only
        // re-assert stacking when the display actually changes.
        if cardTravelsWithChain, card.isVisible {
            let prevScreen = lastCardTravelScreen
            positionCard(promote: false)
            if let head = centres.first {
                let s = screen(nearest: head)
                lastCardTravelScreen = s
                if s !== prevScreen { card.orderFrontRegardless() }
            }
            moving = true
        }

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
    /// app chip first, centered on the card. X packed by *layout* diameters
    /// (hover targets) so zoomed heads do not sit on each other; Y rides the
    /// Dock baseline.
    private func rowSlots() -> [NSPoint] {
        let f = card.frame
        let visible = screen(nearest: NSPoint(x: f.midX, y: f.midY)).visibleFrame
        let baseline = min(f.maxY + 2, visible.maxY - Chain.peak - 2)
        guard !bubbles.isEmpty else { return [] }
        let xs = rowPackedXs(cardFrame: f, visible: visible)
        return bubbles.indices.map { i in
            let d = diameters.indices.contains(i) ? max(diameters[i], Chain.base) : Chain.base
            return NSPoint(x: xs[i], y: baseline + d / 2)
        }
    }

    /// Stable X centres for the docked row — uses layout diameters so packing
    /// only changes when hover focus changes, not every magnification frame.
    private func rowPackedXs(cardFrame f: NSRect, visible: NSRect) -> [CGFloat] {
        Chain.dockedRowXs(
            diameters: bubbles.indices.map { layoutDiameter($0) },
            card: f,
            visible: visible)
    }

    /// One physics step. Returns true while anything is still moving.
    private func integrate(dt: CGFloat, now: CFTimeInterval) -> Bool {
        if docked {
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
            let maxL = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(leader)) * 1.6
            if dist > maxL, dist > 0 {
                let s = maxL / dist
                dx *= s; dyy *= s
                centres[i] = NSPoint(x: tx + dx, y: ty + dyy)
                let nx = dx / maxL, ny = dyy / maxL
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
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i + 1))
                follow(i, leader: i + 1, k: a - i, dy: gap)
            }
        }
        if a < bubbles.count - 1 {
            for i in (a + 1)..<bubbles.count {
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i - 1))
                follow(i, leader: i - 1, k: i - a, dy: -gap)
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
            // Grow toward the screen interior like Dock icons off a baseline:
            // right-edge column keeps its outer (right) rim fixed; left-edge
            // keeps the left rim fixed.
            let d = diameters.indices.contains(i) ? diameters[i] : Chain.base
            // Docked row: packing already owns X and the baseline owns Y growth.
            // Do NOT also edge-bias the panel — that slid the hit circle away from
            // the model centre and made the app chip unreachable under zoom.
            let visualX: CGFloat
            if docked {
                visualX = centres[i].x
            } else {
                let mid = screen(nearest: centres[i]).frame.midX
                visualX = centres[i].x >= mid
                    ? centres[i].x + (Chain.base - d) / 2
                    : centres[i].x + (d - Chain.base) / 2
            }
            let o = NSPoint(x: visualX - Chain.canvas / 2,
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
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if snapped != panel.frame.origin {
                panel.setFrameOrigin(snapped)
            }
            (panel.contentView as? BubbleChipView)?.setDiameter(diameters[i])
        }
        // Panels are peak-sized and overlap when step < canvas. A nil hitTest
        // does NOT fall through to the window below — so without click-through,
        // a neighbour's empty canvas swallows clicks meant for the app chip.
        syncBubbleClickThrough()
    }

    /// Only the head under the cursor (or the one being dragged) accepts mouse
    /// events; every other overlapping panel passes clicks through.
    ///
    /// Uses sticky `hoverFocus` — never re-hit-tests live frames here. Live
    /// geometry moves every zoom frame and would flip ignoresMouseEvents under
    /// a still cursor (the "can't click / jitter" bug).
    ///
    /// The app chip (index 0) is exempt: its context menu must stay reachable
    /// even when sticky hover still names a neighbour.
    private func syncBubbleClickThrough() {
        let live: Int? = dragging ? anchorIndex : hoverFocus
        for i in bubbles.indices {
            var ignore = live.map { $0 != i } ?? true
            if i == 0 { ignore = false }
            if bubbles[i].ignoresMouseEvents != ignore {
                bubbles[i].ignoresMouseEvents = ignore
            }
        }
    }

    /// Hit probes for the docked row — same X packing as `rowSlots`, Y at rest
    /// diameter so zoom cannot feed the hit test.
    private func rowRestSlots() -> [NSPoint] {
        let f = card.frame
        let visible = screen(nearest: NSPoint(x: f.midX, y: f.midY)).visibleFrame
        let baseline = min(f.maxY + 2, visible.maxY - Chain.peak - 2)
        let y = baseline + Chain.base / 2
        return rowPackedXs(cardFrame: f, visible: visible).map { NSPoint(x: $0, y: y) }
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
            let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i + 1))
            centres[i] = NSPoint(x: centres[i + 1].x, y: centres[i + 1].y + gap)
        }
        if a < bubbles.count - 1 {
            for i in (a + 1)..<bubbles.count {
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i - 1))
                centres[i] = NSPoint(x: centres[i - 1].x, y: centres[i - 1].y - gap)
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
        // rightMouseDown (local): app-chip menu must work even when a neighbour
        // panel is the sticky hover target and would otherwise swallow the event.
        let moveDrag: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        let rightClick: NSEvent.EventTypeMask = [.rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moveDrag.union(rightClick),
                                                     handler: { [weak self] e in
            if e.type == .rightMouseDown {
                guard let self, self.isAppChipHit(atScreenPoint: NSEvent.mouseLocation) else { return }
                self.showAppChipMenu(atScreenPoint: NSEvent.mouseLocation)
                return
            }
            self?.handleMonitor(e)
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moveDrag.union(rightClick),
                                                    handler: { [weak self] e in
            if e.type == .rightMouseDown {
                guard let self, self.isAppChipHit(atScreenPoint: NSEvent.mouseLocation) else {
                    return e
                }
                self.showAppChipMenu(atScreenPoint: NSEvent.mouseLocation)
                return nil   // consume — avoid double-firing via the view
            }
            self?.handleMonitor(e)
            return e
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
        syncBubbleClickThrough()
        if before != hoverTargets { wake() }
        followCursorScreenIfNeeded()
    }

    /// When the cursor parks on another display, bring the chain — and the
    /// floating card, when open — onto that display, matching how the avatar
    /// bubbles already follow the active screen. Opt-out via Preferences.
    private func followCursorScreenIfNeeded() {
        guard Preferences.bubbleFollowActiveDisplay else {
            foreignScreenTicks = 0
            return
        }
        guard !dragging, !bubbles.isEmpty, let head = centres.first else {
            foreignScreenTicks = 0
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = screen(nearest: mouse)
        let current = screen(nearest: head)
        guard target !== current else {
            foreignScreenTicks = 0
            return
        }
        // Ignore the shared edge strip — x≈0 between these two displays was
        // flipping the chain every few pixels.
        guard screenInterior(target, contains: mouse, inset: 72) else {
            foreignScreenTicks = 0
            return
        }
        foreignScreenTicks += 1
        if foreignScreenTicks == 1 {
            PlumeTrace.log("  poll: mouse on OTHER screen mouse=\(PlumeTrace.p(mouse)) head=\(PlumeTrace.p(head))")
        }
        guard foreignScreenTicks >= 5 else { return }   // ~160ms at 30 Hz
        foreignScreenTicks = 0
        PlumeTrace.log("\n===== follow-cursor mouse=\(PlumeTrace.p(mouse)) =====")
        if teleportChain(to: target, reason: "follow-cursor") {
            if card.isVisible {
                positionCard()
                promoteOverlayStack()
            }
            wake()
        }
    }

    /// True when `p` sits well inside `screen`'s visible frame, not on the seam.
    private func screenInterior(_ screen: NSScreen, contains p: NSPoint,
                                inset: CGFloat) -> Bool {
        let v = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        if v.width <= 0 || v.height <= 0 { return screen.frame.contains(p) }
        return v.contains(p)
    }

    /// Re-apply sticky focus weights. Does NOT re-pick from geometry — that
    /// belongs in `cursorMoved` / `pollMouse`, otherwise packing springs flip
    /// the winner every frame and the zoom stutters.
    private func refreshHover() { applyHoverFromFocus() }

    /// Slot-based Dock magnification. Vertical column uses Y; the docked card
    /// row uses X. The head that owns the open card stays enlarged even when
    /// the pointer is over a neighbour.
    private func recomputeHoverTargets() {
        let p = NSEvent.mouseLocation
        lastHoverMouse = p
        hoverFocus = pickHoverFocus(at: p)
        applyHoverFromFocus()
    }

    private func applyHoverFromFocus() {
        hoverTargets = Array(repeating: Chain.base, count: bubbles.count)
        guard !dragging, !bubbles.isEmpty else { return }
        let span = Chain.peak - Chain.base
        let open = min(max(lastOpenedIndex, 0), bubbles.count - 1)

        if docked {
            for i in bubbles.indices {
                var w: CGFloat = 0
                if let focus = hoverFocus {
                    switch abs(i - focus) {
                    case 0: w = 1
                    case 1: w = Chain.magNeighbour
                    case 2: w = Chain.magNextNeighbour
                    default: break
                    }
                }
                if i == open { w = max(w, Chain.openBoost) }
                if w > 0 { hoverTargets[i] = Chain.base + span * w }
            }
            if let focus = hoverFocus, focus < hoverTargets.count {
                hoverTargets[focus] = Chain.peak
            }
            return
        }

        guard let focus = hoverFocus else { return }
        for i in bubbles.indices {
            switch abs(i - focus) {
            case 0: hoverTargets[i] = Chain.peak
            case 1: hoverTargets[i] = Chain.base + span * Chain.magNeighbour
            case 2: hoverTargets[i] = Chain.base + span * Chain.magNextNeighbour
            default: break
            }
        }
    }

    /// Pick the head under the pointer from stable rest probes + Euclidean
    /// distance (with hysteresis). Never called from the display tick — packing
    /// springs must not re-elect the winner.
    private func pickHoverFocus(at p: NSPoint) -> Int? {
        guard !bubbles.isEmpty, centres.count == bubbles.count else {
            hoverFocus = nil
            return nil
        }
        let horizontal = docked
        let probes: [NSPoint] = horizontal ? rowRestSlots() : restCentresForHover()
        guard !probes.isEmpty else { hoverFocus = nil; return nil }

        // Soft field around the chain so the Dock glow engages before the tip
        // is dead-centre on a head; hard radius still bounds false hits.
        let fieldR = Chain.peak * 0.72
        var dist = Array(repeating: CGFloat.greatestFiniteMagnitude, count: probes.count)
        for i in probes.indices {
            dist[i] = hypot(p.x - probes[i].x, p.y - probes[i].y)
        }
        guard let nearest = dist.enumerated().min(by: { $0.element < $1.element }),
              nearest.element <= fieldR else {
            hoverFocus = nil
            return nil
        }

        // Hysteresis: keep focus until another probe is clearly closer.
        if let focus = hoverFocus, focus < dist.count, dist[focus] <= fieldR + Chain.step * 0.25 {
            let margin = Chain.step * 0.28
            if nearest.offset != focus, nearest.element < dist[focus] - margin {
                hoverFocus = nearest.offset
            }
            return hoverFocus
        }
        hoverFocus = nearest.offset
        return hoverFocus
    }

    /// Diameter used for chain *spacing* — hover targets, not the animating
    /// visual diameter. Spacing from live `diameters` made the column breathe
    /// under a still cursor and flipped hit tests every frame.
    private func layoutDiameter(_ i: Int) -> CGFloat {
        if hoverTargets.indices.contains(i) { return max(hoverTargets[i], Chain.base) }
        return Chain.base
    }

    /// Unmagnified column through the live anchor — Dock slot positions.
    private func restCentresForHover() -> [NSPoint] {
        let a = min(anchorIndex, max(0, bubbles.count - 1))
        guard centres.indices.contains(a) else { return centres }
        var pts = Array(repeating: NSPoint.zero, count: bubbles.count)
        let x = centres[a].x
        pts[a] = centres[a]
        for i in stride(from: a - 1, through: 0, by: -1) {
            pts[i] = NSPoint(x: x, y: pts[i + 1].y + Chain.step)
        }
        for i in (a + 1)..<bubbles.count {
            pts[i] = NSPoint(x: x, y: pts[i - 1].y - Chain.step)
        }
        return pts
    }

    private func updateTether() {
        guard isExpanded, card.isVisible, !bubbles.isEmpty else {
            tether.hide(); return
        }
        let i = min(max(lastOpenedIndex, 0), bubbles.count - 1)
        guard centres.indices.contains(i) else { tether.hide(); return }
        let d = diameters.indices.contains(i) ? max(diameters[i], Chain.base) : Chain.base
        let from = NSPoint(x: centres[i].x, y: centres[i].y - d / 2)
        let to = NSPoint(x: centres[i].x,
                         y: min(card.frame.maxY - 2, from.y - 4))
        // Cord only when there is a visible gap between head and card.
        guard from.y > to.y + 2 else { tether.hide(); return }
        tether.update(from: from, to: to)
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
        // Undock the row so the chain can trail the cursor across displays, but
        // keep the chat card alive and carry it with the avatars.
        if docked {
            collapseWork?.cancel(); collapseWork = nil
            docked = false
            cardTravelsWithChain = card.isVisible
            lastCardTravelScreen = card.isVisible
                ? screen(nearest: NSPoint(x: card.frame.midX, y: card.frame.midY))
                : nil
            anchorTarget = clampedAnchor(centres[i], index: i)
            PlumeTrace.log("  undock for drag; cardTravels=\(cardTravelsWithChain)")
        } else {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
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

        let mouse = NSEvent.mouseLocation
        let speed = hypot(v.x, v.y)
        let fast = speed >= Chain.flickFloor
        let headScreen = screen(nearest: centres[a])

        // Landing display — cursor first. During a cross-display drag the head
        // often still sits on the old monitor while the cursor is already on the
        // new one; projecting from the head then snaps back to the old edge.
        var land = screen(nearest: mouse)
        if land === headScreen,
           let beyond = screenBeyond(headScreen, velocity: v) {
            land = beyond
        }
        // Dragged to the shared edge but not quite across (trace: release at
        // x=112 with the portrait monitor starting at x=0). Treat "near the
        // seam facing another display" as a hop.
        if land === headScreen,
           let across = screenAcrossSeam(from: centres[a], cursor: mouse) {
            land = across
            PlumeTrace.log("  endDrag SEAM hop → \(PlumeTrace.r(across.frame))")
        }
        if land === headScreen {
            let px = centres[a].x + (fast ? v.x * Chain.projectTauX : 0)
            let py = centres[a].y + (fast ? v.y * Chain.projectTauY : 0)
            land = screen(nearest: NSPoint(x: px, y: py))
        }

        // Hop onto the landing display before choosing the edge, so the spring
        // target is reachable and commit() reassigns each panel's screen.
        // After a hop, lock X to that seam edge — a midX re-pick below used to
        // flip the chain to the opposite side when the flick projected past centre.
        var lockedRight: Bool?
        if land !== headScreen {
            let old = headScreen.visibleFrame, neu = land.visibleFrame
            let fy = old.height > 0 ? (centres[a].y - old.minY) / old.height : 0.5
            let half = Chain.canvas / 2
            let preferRight = DisplayHop.preferRightEdge(
                from: headScreen.frame, to: land.frame, headX: centres[a].x,
                half: half, margin: Chain.margin)
            lockedRight = preferRight
            let edgeX = DisplayHop.edgeX(preferRight: preferRight, visible: neu,
                                         half: half, margin: Chain.margin)
            let edgeY = neu.minY + fy * neu.height
            centres[a] = NSPoint(x: edgeX, y: edgeY)
            for i in centres.indices where i != a {
                centres[i] = NSPoint(x: edgeX,
                                     y: edgeY + CGFloat(a - i) * Chain.step)
                velocities[i] = .zero
            }
            commit()
            PlumeTrace.log("  endDrag HOP → \(PlumeTrace.r(land.frame)) head=\(PlumeTrace.p(centres[a]))")
        }

        let visible = land.visibleFrame
        let half = Chain.canvas / 2
        let left = visible.minX + half + Chain.margin
        let right = visible.maxX - half - Chain.margin
        let above = CGFloat(a) * Chain.step
        let below = CGFloat(bubbles.count - 1 - a) * Chain.step
        let loY = visible.minY + half + Chain.margin + below
        let hiY = visible.maxY - half - Chain.margin - above
        let px = centres[a].x + (fast ? v.x * Chain.projectTauX : 0)
        let py = centres[a].y + (fast ? v.y * Chain.projectTauY : 0)
        let preferRight = lockedRight ?? (px >= visible.midX)
        anchorTarget = NSPoint(
            x: preferRight ? right : left,
            y: loY <= hiY ? min(max(py, loY), hiY) : hiY)
        PlumeTrace.log("  dragEnded mouse=\(PlumeTrace.p(mouse)) head=\(PlumeTrace.p(centres[a])) target=\(PlumeTrace.p(anchorTarget)) land=\(PlumeTrace.r(visible))")
        dragSamples.removeAll()

        // Redock the chat card under the avatars on whichever display we landed.
        if cardTravelsWithChain, card.isVisible {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
            positionCard()
            docked = true
            isExpanded = true
            card.orderFrontRegardless()
            PlumeTrace.log("  card redocked @ \(PlumeTrace.r(card.frame))")
        } else {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
        }
        wake()
    }

    /// The display just past `current`'s edge in the direction of `v`, if any.
    /// Lets a flick aimed at the neighbouring monitor land there even when the
    /// cursor has not quite crossed the seam yet.
    private func screenBeyond(_ current: NSScreen, velocity v: NSPoint) -> NSScreen? {
        guard hypot(v.x, v.y) >= 100 else { return nil }
        let f = current.frame
        var probe = NSPoint(x: f.midX, y: f.midY)
        if abs(v.x) >= abs(v.y) {
            probe.x = v.x < 0 ? f.minX - 40 : f.maxX + 40
        } else {
            probe.y = v.y < 0 ? f.minY - 40 : f.maxY + 40
        }
        return NSScreen.screens.first { $0 !== current && $0.frame.contains(probe) }
    }

    /// If the head/cursor sits in the edge strip of `current` that touches
    /// another display, return that neighbour. Makes "drag to the left edge
    /// of the laptop" land on the portrait monitor without needing to cross
    /// into negative coordinates first.
    private func screenAcrossSeam(from head: NSPoint, cursor: NSPoint) -> NSScreen? {
        let current = screen(nearest: head)
        let f = current.frame
        let seam: CGFloat = 140
        if head.x <= f.minX + seam || cursor.x <= f.minX + seam {
            if let s = NSScreen.screens.first(where: {
                $0 !== current && $0.frame.contains(NSPoint(x: f.minX - 40, y: cursor.y))
            }) { return s }
        }
        if head.x >= f.maxX - seam || cursor.x >= f.maxX - seam {
            if let s = NSScreen.screens.first(where: {
                $0 !== current && $0.frame.contains(NSPoint(x: f.maxX + 40, y: cursor.y))
            }) { return s }
        }
        if head.y <= f.minY + seam || cursor.y <= f.minY + seam {
            if let s = NSScreen.screens.first(where: {
                $0 !== current && $0.frame.contains(NSPoint(x: cursor.x, y: f.minY - 40))
            }) { return s }
        }
        if head.y >= f.maxY - seam || cursor.y >= f.maxY - seam {
            if let s = NSScreen.screens.first(where: {
                $0 !== current && $0.frame.contains(NSPoint(x: cursor.x, y: f.maxY + 40))
            }) { return s }
        }
        return nil
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
