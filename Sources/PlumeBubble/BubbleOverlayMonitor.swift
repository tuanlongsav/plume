import AppKit
import PlumeCore

/// Owns global + local mouse monitors and the 30 Hz mouse poll that keep
/// cross-display drags, Dock hover magnification, active-display following and
/// fullscreen overlay keep-alive running while bubble mode is live.
final class BubbleOverlayMonitor {
    private let screens: ScreenResolver
    private var mouseMonitors: [Any] = []
    /// Polls `mouseLocation` while bubble mode is live. Global mouse monitors
    /// silently drop events across display boundaries on current macOS (and
    /// need Accessibility for some paths); a 30 Hz poll needs neither and is
    /// what actually lets a drag finish on the other screen.
    private var mousePoll: Timer?
    private var pollMotion = DisplayHop.PollMotion()
    private var foreignScreenTicks = 0
    /// Periodically re-assert overlay stacking so collapsed heads and the
    /// titled card stay above newly entered fullscreen Spaces.
    private var overlayKeepAliveTicks = 0
    private var lastHoverMouse: NSPoint?

    var isDragging: () -> Bool = { false }
    var headCentre: () -> NSPoint? = { nil }
    var isAppChipHit: (NSPoint) -> Bool = { _ in false }
    var onAppChipRightClick: (NSPoint) -> Void = { _ in }
    var onDragMove: (NSPoint) -> Void = { _ in }
    var onDragEndFromMonitor: (NSPoint) -> Void = { _ in }
    var onDragEndFromPoll: (NSPoint) -> Void = { _ in }
    var onHoverUpdate: (NSPoint) -> Void = { _ in }
    var onSyncClickThrough: () -> Void = {}
    var onFollowCursorToScreen: (NSScreen) -> Void = { _ in }
    var onOverlayKeepAlive: () -> Void = {}

    init(screens: ScreenResolver) {
        self.screens = screens
    }

    deinit { stop() }

    func start() {
        installMouseMonitors()
        startMousePoll()
    }

    func stop() {
        mousePoll?.invalidate()
        mousePoll = nil
        pollMotion = DisplayHop.PollMotion()
        foreignScreenTicks = 0
        overlayKeepAliveTicks = 0
        lastHoverMouse = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    func resetForeignScreenTicks() {
        foreignScreenTicks = 0
    }

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
            guard let self else { return }
            if e.type == .rightMouseDown {
                let p = NSEvent.mouseLocation
                guard self.isAppChipHit(p) else { return }
                self.onAppChipRightClick(p)
                return
            }
            self.handleMonitor(e)
        }) { mouseMonitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: moveDrag.union(rightClick),
                                                    handler: { [weak self] e in
            guard let self else { return e }
            if e.type == .rightMouseDown {
                let p = NSEvent.mouseLocation
                guard self.isAppChipHit(p) else { return e }
                self.onAppChipRightClick(p)
                return nil   // consume — avoid double-firing via the view
            }
            self.handleMonitor(e)
            return e
        }) { mouseMonitors.append(l) }
    }

    private func startMousePoll() {
        guard mousePoll == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        // Lets the system coalesce this wake-up with others; it runs for as
        // long as bubble mode is on (AGENTS.md rule 7), so give it half a
        // period of slack rather than a quarter.
        t.tolerance = 0.015
        RunLoop.main.add(t, forMode: .common)
        mousePoll = t
    }

    private func handleMonitor(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseUp:
            // Idempotent with the chip's own mouseUp: whichever arrives first wins.
            if isDragging() {
                PlumeTrace.log("  drag mouseUp@\(PlumeTrace.p(p)) via monitor")
                onDragEndFromMonitor(p)
            }
        case .leftMouseDragged:
            if isDragging() { onDragMove(p) }
            cursorMoved(to: p)
        default:
            cursorMoved(to: p)
        }
    }

    /// Cheap enough for every mouse-moved event: it only wakes the loop when the
    /// answer actually changed, so a cursor elsewhere on screen costs nothing.
    /// Following the cursor to another display is left to `pollMouse`: its
    /// debounce counts 30 Hz ticks, and feeding it every mouse event too
    /// shrank the ~160ms wait to a few milliseconds on a fast mouse.
    private func cursorMoved(to p: NSPoint) {
        lastHoverMouse = p
        onHoverUpdate(p)
    }

    private func pollMouse() {
        guard !NSScreen.screens.isEmpty else { return }
        let p = NSEvent.mouseLocation
        if isDragging() {
            // Button released on another display never reaches the chip view.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                PlumeTrace.log("  drag mouseUp@\(PlumeTrace.p(p)) via poll")
                onDragEndFromPoll(p)
            } else {
                onDragMove(p)
            }
            return
        }
        // Only re-pick when the pointer actually moved. Re-sampling every poll
        // against packing centres flipped focus under a still cursor.
        let moved = lastHoverMouse.map { hypot(p.x - $0.x, p.y - $0.y) >= 0.5 } ?? true
        if moved {
            lastHoverMouse = p
            onHoverUpdate(p)
        } else {
            onSyncClickThrough()
        }
        // A pointer at rest cannot newly reach another display; only a hop
        // already being counted down (`foreignScreenTicks`) needs the
        // stationary ticks. Skips two screen searches on every idle poll.
        // `pollMotion`, not `moved`: see `DisplayHop.PollMotion`.
        let movedSincePoll = pollMotion.moved(to: p)
        if movedSincePoll || foreignScreenTicks > 0 {
            followCursorScreenIfNeeded(mouse: p)
        }
        // Collapsed heads need the same keep-alive: without it they sink behind
        // a newly entered fullscreen Space until the user leaves that Space.
        overlayKeepAliveTicks += 1
        if overlayKeepAliveTicks >= 90 {   // ~3s at 30 Hz
            overlayKeepAliveTicks = 0
            onOverlayKeepAlive()
        }
    }

    /// When the cursor parks on another display, bring the chain — and the
    /// floating card, when open — onto that display. Opt-out via Preferences.
    private func followCursorScreenIfNeeded(mouse: NSPoint) {
        guard Preferences.bubbleFollowActiveDisplay,
              !isDragging(),
              let head = headCentre() else {
            foreignScreenTicks = 0
            return
        }
        let target = screens.nearest(to: mouse)
        let current = screens.nearest(to: head)
        guard target !== current else {
            foreignScreenTicks = 0
            return
        }
        // Ignore the shared edge strip — x≈0 between two displays was
        // flipping the chain every few pixels.
        guard screens.isInterior(target, contains: mouse, inset: 72) else {
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
        onFollowCursorToScreen(target)
    }
}
