import AppKit
import PlumeUI

/// Detects Messenger's photo/video lightbox while a thread is open in the
/// bubble card and temporarily expands the card to fill the display (then
/// restores its saved size once the lightbox closes).
final class BubbleTheaterController {
    private(set) var isActive = false
    private var preTheaterSize: NSSize?
    /// Debounce theatre open/close so a one-frame DOM blip cannot thrash size.
    private var openTicks = 0
    private var closeTicks = 0
    /// Right after expanding, theatre may still be re-laying out — do not
    /// restore the small card until this deadline (or until it is seen, then lost).
    private var holdUntil: CFTimeInterval = 0
    private var pollTimer: Timer?

    private weak var card: BubbleCardPanel?
    private weak var pageBridge: BubblePageBridge?
    private let hostScreen: () -> NSScreen
    private let isThreadShowing: () -> Bool
    private let onPushCardClip: () -> Void
    private let onDidEnter: () -> Void
    private let onDidExitRestored: () -> Void

    init(card: BubbleCardPanel,
         pageBridge: BubblePageBridge,
         hostScreen: @escaping () -> NSScreen,
         isThreadShowing: @escaping () -> Bool,
         onPushCardClip: @escaping () -> Void,
         onDidEnter: @escaping () -> Void,
         onDidExitRestored: @escaping () -> Void) {
        self.card = card
        self.pageBridge = pageBridge
        self.hostScreen = hostScreen
        self.isThreadShowing = isThreadShowing
        self.onPushCardClip = onPushCardClip
        self.onDidEnter = onDidEnter
        self.onDidExitRestored = onDidExitRestored
    }

    deinit { stopPolling() }

    /// Poll theatre open/close while a thread is showing in the card.
    func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self, self.isThreadShowing() else { return }
            // Covered or on another Space: nobody can open a photo in it, and
            // each detect pass walks every image in the page.
            guard self.card?.occlusionState.contains(.visible) == true else { return }
            self.pollOnce()
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        pageBridge?.detectTheater { [weak self] open in
            guard let self, self.isThreadShowing() else { return }
            if open {
                self.closeTicks = 0
                self.holdUntil = 0
                self.openTicks += 1
                // Two ticks (~0.44s): a one-frame emoji/reaction dialog must
                // not expand the card. Photo theatre stays open well past that.
                if self.openTicks >= 2 { self.enter() }
            } else {
                self.openTicks = 0
                if CACurrentMediaTime() < self.holdUntil { return }
                self.closeTicks += 1
                if self.closeTicks >= 3 { self.exit(restore: true) }
            }
        }
    }

    private func enter() {
        if isActive {
            holdUntil = max(holdUntil, CACurrentMediaTime() + 0.8)
            return
        }
        guard isThreadShowing(), let card else { return }
        isActive = true
        openTicks = 2
        closeTicks = 0
        holdUntil = CACurrentMediaTime() + 2.0
        preTheaterSize = card.contentRect(forFrameRect: card.frame).size

        onPushCardClip()

        let visible = hostScreen().visibleFrame
        let size = BubbleCardLayout.theaterContentSize(
            minSize: card.minSize, visible: visible, peakDiameter: Chain.peak)
        card.setContentSize(size)
        let frameSize = card.frame.size
        let origin = BubbleCardLayout.theaterOrigin(
            frameSize: frameSize, visible: visible, peakDiameter: Chain.peak)
        card.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        PlumeOverlay.apply(to: card)
        card.orderFrontRegardless()
        onDidEnter()
    }

    func exit(restore: Bool) {
        guard isActive else { return }
        isActive = false
        openTicks = 0
        closeTicks = 0
        holdUntil = 0
        if restore, let saved = preTheaterSize, let card {
            let size = BubbleCardLayout.restoredTheaterSize(
                saved: saved, minSize: card.minSize,
                visible: hostScreen().visibleFrame, peakDiameter: Chain.peak)
            card.setContentSize(size)
        }
        preTheaterSize = nil
        onPushCardClip()
        if restore, let card, card.isVisible {
            onDidExitRestored()
        }
    }
}
