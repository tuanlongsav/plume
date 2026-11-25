import AppKit
import PlumeCore

/// Owns the bubble chain's head store, spring physics, Dock hover magnification,
/// drag/flick gestures, multi-display teleporting and per-frame panel commit.
final class BubbleChainPhysics {
    var store = BubbleChainStore<BubblePanel>()
    let screens: ScreenResolver

    var anchorTarget: NSPoint = .zero
    /// While the card is open the chain leaves its column and docks in a row
    /// along the top of it, so any conversation is one click away.
    var docked = false
    private(set) var dragging = false
    private var dragGrabOffset: NSPoint = .zero
    private var dragCursor: NSPoint = .zero
    private var dragSamples: [(p: NSPoint, t: CFTimeInterval)] = []

    /// Card stays on-screen and hops with the avatar chain during a drag that
    /// started while docked — instead of orderOut'ing and leaving the chat behind.
    var cardTravelsWithChain = false
    var lastCardTravelScreen: NSScreen?

    var cardFrame: () -> NSRect = { .zero }
    var isCardVisible: () -> Bool = { false }
    var onBeforeUndockForDrag: () -> Void = {}
    var onPositionCard: (_ promote: Bool) -> Void = { _ in }
    var onOrderCardFront: () -> Void = {}
    var onCardRedocked: () -> Void = {}
    var onWake: () -> Void = {}
    var onResetForeignScreenTicks: () -> Void = {}

    init(screens: ScreenResolver) {
        self.screens = screens
    }

    // MARK: Convenience accessors

    func chip(of panel: BubblePanel) -> BubbleChipView? {
        panel.contentView as? BubbleChipView
    }

    func index(of panel: BubblePanel) -> Int? {
        store.heads.firstIndex { $0.panel === panel }
    }

    var anchorScreen: NSScreen {
        let a = store.anchorIndex
        let p = store.indices.contains(a) ? store[a].centre : (store.heads.first?.centre ?? .zero)
        return screens.nearest(to: p)
    }

    /// Display the chain (and therefore the card) should live on right now.
    var hostScreen: NSScreen {
        let p = store.heads.first?.centre ?? NSPoint(x: cardFrame().midX, y: cardFrame().midY)
        return screens.nearest(to: p)
    }

    func clampedAnchor(_ p: NSPoint, index a: Int = 0) -> NSPoint {
        Chain.clampedAnchor(p, visible: screens.nearest(to: p).visibleFrame,
                            count: store.count, anchorIndex: a)
    }

    /// Re-read where the window server actually put the heads.
    func syncCentresFromPanels() {
        for i in store.indices {
            let f = store[i].panel.frame
            store[i].centre = NSPoint(x: f.midX, y: f.midY)
        }
    }

    // MARK: Anchor persistence

    func saveAnchor() {
        guard let c = store.heads.first?.centre else { return }
        Preferences.bubbleOrigin = c
    }

    func savedHeadCentre() -> NSPoint {
        var c: NSPoint
        if let saved = Preferences.bubbleOrigin {
            c = saved
        } else {
            let v = (NSScreen.main ?? screens.nearest(to: .zero)).visibleFrame
            c = NSPoint(x: v.maxX - Chain.canvas / 2 - Chain.margin,
                        y: v.maxY - Chain.canvas / 2 - 80)
        }
        // Through the same clamp the simulation uses — a margin's difference
        // here is enough to make the chain unable to reach its own anchor.
        return clampedAnchor(c)
    }

    // MARK: Multi-display teleport

    /// Bring the chain onto the display the user is actually working on.
    func adoptScreenUnderCursor() {
        guard Preferences.bubbleFollowActiveDisplay else {
            PlumeTrace.log("  adopt: BỎ QUA (giữ màn hình hiện tại)")
            return
        }
        guard !store.isEmpty else {
            PlumeTrace.log("  adopt: BỎ QUA (không có head)")
            return
        }
        let target = screens.nearest(to: NSEvent.mouseLocation)
        teleportChain(to: target, reason: "adopt")
    }

    /// Instantly re-park the whole chain onto `target` on a vertical edge.
    /// Side-by-side displays land on the shared seam; height is preserved.
    /// Springing across the gap between monitors reads as a glitch, not motion.
    @discardableResult
    func teleportChain(to target: NSScreen, reason: String) -> Bool {
        guard let head = store.heads.first?.centre else { return false }
        let current = screens.nearest(to: head)
        PlumeTrace.log("  teleport(\(reason)): from=\(PlumeTrace.r(current.frame)) to=\(PlumeTrace.r(target.frame)) giống nhau=\(target === current)")
        guard target !== current else { return false }

        let landing = DisplayHop.hopLanding(
            from: current.frame, fromVisible: current.visibleFrame,
            to: target.frame, toVisible: target.visibleFrame,
            head: head, half: Chain.canvas / 2, margin: Chain.margin)
        store.anchorIndex = 0
        anchorTarget = clampedAnchor(landing.point)
        PlumeTrace.log("  teleport edge=\(landing.preferRight ? "right" : "left") target=\(PlumeTrace.p(anchorTarget))")
        for i in store.indices {
            store[i].centre = NSPoint(x: anchorTarget.x, y: anchorTarget.y - CGFloat(i) * Chain.step)
            store[i].velocity = .zero
        }
        commit()
        saveAnchor()
        return true
    }

    // MARK: Hover magnification

    /// Re-pick focus from pointer `p` and refresh target diameters. Returns
    /// true when any target diameter changed (caller should wake the frame loop).
    @discardableResult
    func updateHover(at p: NSPoint) -> Bool {
        let before = store.heads.map(\.hoverTarget)
        if store.isEmpty {
            store.hoverFocus = nil
        } else {
            let probes = docked ? rowRestSlots() : restCentresForHover()
            store.hoverFocus = Chain.pickHoverFocus(point: p, probes: probes,
                                                    currentFocus: store.hoverFocus)
        }
        applyHoverFromFocus()
        syncBubbleClickThrough()
        return before != store.heads.map(\.hoverTarget)
    }

    func applyHoverFromFocus() {
        let targets = Chain.hoverTargets(
            count: store.count,
            focus: store.hoverFocus,
            docked: docked,
            openIndex: store.lastOpenedIndex,
            dragging: dragging
        )
        for i in store.indices {
            store[i].hoverTarget = targets[i]
        }
    }

    /// Diameter used for chain *spacing* — hover targets, not the animating
    /// visual diameter. Spacing from live `diameters` made the column breathe
    /// under a still cursor and flipped hit tests every frame.
    func layoutDiameter(_ i: Int) -> CGFloat {
        guard store.indices.contains(i) else { return Chain.base }
        return max(store[i].hoverTarget, Chain.base)
    }

    /// Unmagnified column through the live anchor — Dock slot positions.
    private func restCentresForHover() -> [NSPoint] {
        let a = min(store.anchorIndex, max(0, store.count - 1))
        guard store.indices.contains(a) else { return store.heads.map(\.centre) }
        var pts = Array(repeating: NSPoint.zero, count: store.count)
        let x = store[a].centre.x
        pts[a] = store[a].centre
        for i in stride(from: a - 1, through: 0, by: -1) {
            pts[i] = NSPoint(x: x, y: pts[i + 1].y + Chain.step)
        }
        for i in (a + 1)..<store.count {
            pts[i] = NSPoint(x: x, y: pts[i - 1].y - Chain.step)
        }
        return pts
    }

    /// Where each head sits while the card is open: a row across the top of it,
    /// app chip first, centered on the card.
    func rowSlots() -> [NSPoint] {
        guard !store.isEmpty else { return [] }
        let f = cardFrame()
        let visible = screens.nearest(to: NSPoint(x: f.midX, y: f.midY)).visibleFrame
        let baseline = Chain.dockedBaselineY(card: f, visible: visible)
        let xs = rowPackedXs(cardFrame: f, visible: visible)
        return store.indices.map { i in
            let d = max(store[i].diameter, Chain.base)
            return NSPoint(x: xs[i], y: baseline + d / 2)
        }
    }

    /// Hit probes for the docked row — same X packing as `rowSlots`, Y at rest
    /// diameter so zoom cannot feed the hit test.
    private func rowRestSlots() -> [NSPoint] {
        let f = cardFrame()
        let visible = screens.nearest(to: NSPoint(x: f.midX, y: f.midY)).visibleFrame
        let baseline = Chain.dockedBaselineY(card: f, visible: visible)
        let y = baseline + Chain.base / 2
        return rowPackedXs(cardFrame: f, visible: visible).map { NSPoint(x: $0, y: y) }
    }

    private func rowPackedXs(cardFrame f: NSRect, visible: NSRect) -> [CGFloat] {
        Chain.dockedRowXs(diameters: store.indices.map { layoutDiameter($0) },
                          card: f, visible: visible)
    }

    /// Place every head straight onto its packed docked-row slot before the
    /// first docked frame renders.
    func snapHeadsToDockedRow() {
        let slots = rowSlots()
        for i in store.indices where i < slots.count {
            store[i].centre = slots[i]
            store[i].velocity = .zero
        }
    }

    // MARK: Physics integration & commit

    /// One physics step. Returns true while anything is still moving.
    func integrate(dt: CGFloat, now: CFTimeInterval) -> Bool {
        if docked {
            // Every head flies to its own slot rather than chasing the one in
            // front: a chain would arrive as a whip, and this is a toolbar.
            // The per-index τ ramp still lands them in a cascade.
            let slots = rowSlots()
            var moving = false
            for i in store.indices {
                let t = slots[i]
                let w = 2 * Chain.trailZeta / Chain.trailTau(i + 1)
                store[i].stepSpring(to: t, omega: w, zeta: Chain.trailZeta, dt: dt)
                if abs(store[i].centre.x - t.x) > Chain.restDistance
                    || abs(store[i].centre.y - t.y) > Chain.restDistance { moving = true }
            }
            if store.heads.contains(where: { now < $0.born }) { moving = true }
            return moving
        }

        let a = min(store.anchorIndex, store.count - 1)
        if dragging {
            store[a].centre = NSPoint(x: dragCursor.x + dragGrabOffset.x,
                                      y: dragCursor.y + dragGrabOffset.y)
            store[a].velocity = .zero
        } else {
            // At rest the whole chain shares one display — the anchor's.
            let b = Chain.screenBand(visible: anchorScreen.visibleFrame, overshoot: Chain.maxOvershoot)
            store[a].stepSpring(to: anchorTarget, omega: Chain.anchorOmega, zeta: Chain.anchorZeta, dt: dt)
            // The flick is carried into the spring, so ζ 0.9 still overshoots.
            // Allow a visible settle, never a bubble off the screen.
            store[a].clamp(to: b)
        }

        var moving = dragging
        func follow(_ i: Int, leader: Int, k: Int, dy: CGFloat) {
            let tx = store[leader].centre.x, ty = store[leader].centre.y + dy
            let w = 2 * Chain.trailZeta / Chain.trailTau(k)
            store[i].stepSpring(to: CGPoint(x: tx, y: ty), omega: w, zeta: Chain.trailZeta, dt: dt)

            // Rope constraint: bound cumulative lag during fast drags/flicks.
            var dx = store[i].centre.x - tx, dyy = store[i].centre.y - ty
            let dist = (dx * dx + dyy * dyy).squareRoot()
            let maxL = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(leader)) * 1.6
            if dist > maxL, dist > 0 {
                let s = maxL / dist
                dx *= s; dyy *= s
                store[i].centre = NSPoint(x: tx + dx, y: ty + dyy)
                let nx = dx / maxL, ny = dyy / maxL
                let outward = store[i].velocity.x * nx + store[i].velocity.y * ny
                if outward > 0 {
                    store[i].velocity.x -= outward * nx
                    store[i].velocity.y -= outward * ny
                }
            }
            // Followers get no overshoot budget: hard clamp to THEIR screen.
            let b = Chain.screenBand(visible: screens.nearest(to: store[i].centre).visibleFrame)
            store[i].clamp(to: b)

            // Against the clamped target, not the raw one: a target outside
            // the screen band is unreachable, and comparing to it would keep
            // `moving` true forever.
            let rx = min(max(tx, b.loX), b.hiX), ry = min(max(ty, b.loY), b.hiY)
            if abs(store[i].centre.x - rx) > Chain.restDistance
                || abs(store[i].centre.y - ry) > Chain.restDistance { moving = true }
        }

        if a > 0 {
            for i in stride(from: a - 1, through: 0, by: -1) {
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i + 1))
                follow(i, leader: i + 1, k: a - i, dy: gap)
            }
        }
        if a < store.count - 1 {
            for i in (a + 1)..<store.count {
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i - 1))
                follow(i, leader: i - 1, k: i - a, dy: -gap)
            }
        }

        if !dragging {
            let b = Chain.screenBand(visible: anchorScreen.visibleFrame, overshoot: Chain.maxOvershoot)
            let ax = min(max(anchorTarget.x, b.loX), b.hiX)
            let ay = min(max(anchorTarget.y, b.loY), b.hiY)
            let rest = max(abs(store[a].centre.x - ax), abs(store[a].centre.y - ay))
            let speed = store.heads.reduce(CGFloat(0)) {
                max($0, max(abs($1.velocity.x), abs($1.velocity.y)))
            }
            if rest > Chain.restDistance || speed > Chain.restSpeed { moving = true }
        }
        if store.heads.contains(where: { now < $0.born }) { moving = true }
        return moving
    }

    func advanceMagnification(dt: CGFloat) -> Bool {
        let k = 1 - exp(-Chain.magRate * dt)
        var moving = false
        let now = CACurrentMediaTime()
        for i in store.indices {
            let want = now < store[i].born ? 0 : store[i].hoverTarget   // staggered pop-in
            if abs(want - store[i].diameter) < Chain.magEpsilon {
                store[i].diameter = want
            } else {
                store[i].diameter += (want - store[i].diameter) * k
                moving = true
            }
        }
        return moving
    }

    /// Six setFrameOrigin calls and six layer transforms. Nothing else belongs
    /// in a display-link callback — no layout, no display(), no image decode.
    func commit() {
        for i in store.indices {
            let head = store[i]
            let panel = head.panel
            let scale = max(panel.backingScaleFactor, 1)
            let d = head.diameter
            // Docked row: packing already owns X and the baseline owns Y growth.
            // Column: grow toward the screen interior like Dock icons off an edge.
            let destScreen = screens.nearest(to: head.centre)
            let visualX: CGFloat
            if docked {
                visualX = head.centre.x
            } else {
                let mid = destScreen.frame.midX
                visualX = head.centre.x >= mid
                    ? head.centre.x + (Chain.base - d) / 2
                    : head.centre.x + (d - Chain.base) / 2
            }
            let o = NSPoint(x: visualX - Chain.canvas / 2,
                            y: head.centre.y - Chain.canvas / 2)
            // Snap to the backing grid, not to integer points — rounding to
            // points throws away half the smoothness 120Hz just bought.
            let snapped = NSPoint(x: (o.x * scale).rounded() / scale,
                                  y: (o.y * scale).rounded() / scale)
            let dest = NSRect(origin: snapped, size: panel.frame.size)
            // Crossing displays: setFrameOrigin alone can leave the panel's
            // screen association on the old monitor. setFrame forces the hop.
            if panel.screen !== destScreen {
                panel.setFrame(dest, display: false)
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if snapped != panel.frame.origin {
                panel.setFrameOrigin(snapped)
            }
            chip(of: panel)?.setDiameter(d)
        }
        syncBubbleClickThrough()
    }

    /// Only the head under the cursor (or the one being dragged) accepts mouse
    /// events; every other overlapping panel passes clicks through.
    ///
    /// Uses sticky `hoverFocus` — never re-hit-tests live frames here.
    /// The app chip (index 0) is exempt so its context menu stays reachable.
    func syncBubbleClickThrough() {
        let live: Int? = dragging ? store.anchorIndex : store.hoverFocus
        for i in store.indices {
            var ignore = live.map { $0 != i } ?? true
            if i == 0 { ignore = false }
            if store[i].panel.ignoresMouseEvents != ignore {
                store[i].panel.ignoresMouseEvents = ignore
            }
        }
    }

    /// Land on exact pixels so a resting chain is perfectly aligned.
    func snapToRest(anchor a: Int) {
        if docked, isCardVisible() {
            snapHeadsToDockedRow()
            commit()
            return          // the row is a temporary dock, not the chain's home
        }
        guard store.indices.contains(a) else { return }
        store[a].centre = anchorTarget
        for i in store.indices { store[i].velocity = .zero }
        for i in stride(from: a - 1, through: 0, by: -1) {
            let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i + 1))
            store[i].centre = NSPoint(x: store[i + 1].centre.x, y: store[i + 1].centre.y + gap)
        }
        if a < store.count - 1 {
            for i in (a + 1)..<store.count {
                let gap = Chain.linkSpacing(layoutDiameter(i), layoutDiameter(i - 1))
                store[i].centre = NSPoint(x: store[i - 1].centre.x, y: store[i - 1].centre.y - gap)
            }
        }
        commit()
        saveAnchor()
    }

    // MARK: Drag & flick gestures

    func beginDrag(_ panel: BubblePanel, grab: NSPoint) {
        guard let i = index(of: panel) else { return }
        // Undock the row so the chain can trail the cursor across displays, but
        // keep the chat card alive and carry it with the avatars.
        if docked {
            onBeforeUndockForDrag()
            docked = false
            let visible = isCardVisible()
            cardTravelsWithChain = visible
            let cf = cardFrame()
            lastCardTravelScreen = visible ? screens.nearest(to: NSPoint(x: cf.midX, y: cf.midY)) : nil
            anchorTarget = clampedAnchor(store[i].centre, index: i)
            PlumeTrace.log("  undock for drag; cardTravels=\(cardTravelsWithChain)")
        } else {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
        }
        store.anchorIndex = i
        dragging = true
        dragCursor = grab
        dragGrabOffset = NSPoint(x: store[i].centre.x - grab.x, y: store[i].centre.y - grab.y)
        dragSamples = [(grab, CACurrentMediaTime())]
        onResetForeignScreenTicks()
        PlumeTrace.log("\n===== dragBegan head=\(PlumeTrace.p(store[i].centre)) screen=\(PlumeTrace.r(screens.nearest(to: store[i].centre).frame)) =====")
        onWake()
    }

    func dragTo(_ cursor: NSPoint) {
        guard dragging else { return }
        dragCursor = cursor
        dragSamples.append((cursor, CACurrentMediaTime()))
        if dragSamples.count > Chain.velSamples { dragSamples.removeFirst() }
        onWake()
    }

    func endDragUsingRecordedSamples() {
        endDrag(velocity: Chain.flickVelocity(dragSamples))
    }

    /// Release: the flick is loaded straight into the anchor spring, which lands
    /// on the nearest edge and keeps the whole chain — not just the grabbed
    /// bubble — on screen.
    func endDrag(velocity: NSPoint) {
        guard dragging else { return }   // idempotent; a stray call is a no-op
        dragging = false
        store.heads.forEach { chip(of: $0.panel)?.cancelPress() }
        let a = min(store.anchorIndex, max(0, store.count - 1))
        guard store.indices.contains(a) else { return }

        let v = NSPoint(x: max(-Chain.maxFlick, min(Chain.maxFlick, velocity.x)),
                        y: max(-Chain.maxFlick, min(Chain.maxFlick, velocity.y)))
        store[a].velocity = v

        let mouse = NSEvent.mouseLocation
        let speed = hypot(v.x, v.y)
        let fast = speed >= Chain.flickFloor
        let headScreen = screens.nearest(to: store[a].centre)

        // Landing display — cursor first. During a cross-display drag the head
        // often still sits on the old monitor while the cursor is already on the
        // new one; projecting from the head then snaps back to the old edge.
        var land = screens.nearest(to: mouse)
        if land === headScreen, let beyond = screens.beyond(headScreen, velocity: v) {
            land = beyond
        }
        // Dragged to the shared edge but not quite across: treat "near the seam
        // facing another display" as a hop.
        if land === headScreen, let across = screens.acrossSeam(from: store[a].centre, cursor: mouse) {
            land = across
            PlumeTrace.log("  endDrag SEAM hop → \(PlumeTrace.r(across.frame))")
        }
        if land === headScreen {
            let px = store[a].centre.x + (fast ? v.x * Chain.projectTauX : 0)
            let py = store[a].centre.y + (fast ? v.y * Chain.projectTauY : 0)
            land = screens.nearest(to: NSPoint(x: px, y: py))
        }

        // Hop onto the landing display before choosing the edge, so the spring
        // target is reachable and commit() reassigns each panel's screen.
        var lockedRight: Bool?
        if land !== headScreen {
            let landing = DisplayHop.hopLanding(
                from: headScreen.frame, fromVisible: headScreen.visibleFrame,
                to: land.frame, toVisible: land.visibleFrame,
                head: store[a].centre, half: Chain.canvas / 2, margin: Chain.margin)
            lockedRight = landing.preferRight
            store[a].centre = landing.point
            for i in store.indices where i != a {
                store[i].centre = NSPoint(x: landing.point.x,
                                          y: landing.point.y + CGFloat(a - i) * Chain.step)
                store[i].velocity = .zero
            }
            commit()
            PlumeTrace.log("  endDrag HOP → \(PlumeTrace.r(land.frame)) head=\(PlumeTrace.p(store[a].centre))")
        }

        let visible = land.visibleFrame
        let bounds = Chain.restingAnchorBounds(visible: visible, count: store.count, anchorIndex: a)
        let px = store[a].centre.x + (fast ? v.x * Chain.projectTauX : 0)
        let py = store[a].centre.y + (fast ? v.y * Chain.projectTauY : 0)
        let preferRight = lockedRight ?? (px >= visible.midX)
        anchorTarget = NSPoint(
            x: preferRight ? bounds.hiX : bounds.loX,
            y: bounds.loY <= bounds.hiY ? min(max(py, bounds.loY), bounds.hiY) : bounds.hiY)
        PlumeTrace.log("  dragEnded mouse=\(PlumeTrace.p(mouse)) head=\(PlumeTrace.p(store[a].centre)) target=\(PlumeTrace.p(anchorTarget)) land=\(PlumeTrace.r(visible))")
        dragSamples.removeAll()

        // Redock the chat card under the avatars on whichever display we landed.
        if cardTravelsWithChain, isCardVisible() {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
            onPositionCard(true)
            docked = true
            onCardRedocked()
            PlumeTrace.log("  card redocked @ \(PlumeTrace.r(cardFrame()))")
        } else {
            cardTravelsWithChain = false
            lastCardTravelScreen = nil
        }
        onWake()
    }
}

private extension BubbleHead {
    @inline(__always)
    mutating func stepSpring(to target: CGPoint, omega: CGFloat, zeta: CGFloat, dt: CGFloat) {
        Chain.spring(&centre.x, &velocity.x, to: target.x, omega: omega, zeta: zeta, dt: dt)
        Chain.spring(&centre.y, &velocity.y, to: target.y, omega: omega, zeta: zeta, dt: dt)
    }

    @inline(__always)
    mutating func clamp(to bounds: Chain.Bounds) {
        Chain.clamp(&centre.x, &velocity.x, bounds.loX, bounds.hiX)
        Chain.clamp(&centre.y, &velocity.y, bounds.loY, bounds.hiY)
    }
}
