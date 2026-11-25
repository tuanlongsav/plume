import AppKit
import PlumeCore
import PlumeUI
import QuartzCore
import WebKit

/// Owns the floating chat card panel, the tether, the native conversation
/// picker (with pagination), photo-theatre expansion, thread opening / fixup /
/// scroll-to-latest ladders, fold/unfold animations and auto-collapse.
final class BubbleCardCoordinator: NSObject, NSWindowDelegate {
    let card: BubbleCardPanel
    let tether = BubbleTetherPanel()
    private let listView = ConversationListView(frame: .zero)
    private let pageBridge: BubblePageBridge
    private let physics: BubbleChainPhysics
    private let screens: ScreenResolver
    private var theater: BubbleTheaterController!

    private(set) var isExpanded = false
    private(set) var showingPicker = false
    private var collapseWork: DispatchWorkItem?
    /// True while a system file/photo picker sheet is up — resignKey must not
    /// fold the card mid-attach.
    private var attachmentPickerActive = false
    /// True while `positionCard` has the card ordered out to move it between
    /// displays — that resignKey is ours, not the user clicking away.
    private var relocatingCard = false
    private var observingURL = false

    private let fixupLadder = DelayedLadder()
    private let scrollLadder = DelayedLadder()
    private static let fixupDelays: [TimeInterval] = [0, 0.15, 0.4, 0.9, 1.6, 2.6, 4.0]
    private static let scrollDelays: [TimeInterval] = [0.05, 0.2, 0.45, 0.9, 1.6, 2.8]

    /// How many inbox rows the picker currently asks Messenger for.
    private var pickerLimit = 24
    private var lastPickerCount = 0
    private var pickerStalls = 0
    private static let pickerPage = 24
    private static let pickerMax = 200

    var onPromoteOverlayStack: () -> Void = {}
    var onScheduleOverlayPromote: (_ whileExpandedOnly: Bool) -> Void = { _ in }
    var onWake: () -> Void = {}
    var onRefreshUnreadFlags: () -> Void = {}
    var onPromoteConversation: (BubbleConversation) -> Void = { _ in }
    var onSpawnConversation: (BubbleConversation) -> Void = { _ in }
    var onRemoveConversationHead: (String) -> Void = { _ in }
    var onClearBadgeForConversation: (String) -> Void = { _ in }
    var onOrderBubblesFront: () -> Void = {}

    var webView: WKWebView { pageBridge.webView }
    var sheetHost: NSWindow? { isExpanded ? card : nil }

    init(pageBridge: BubblePageBridge, physics: BubbleChainPhysics, screens: ScreenResolver) {
        self.pageBridge = pageBridge
        self.physics = physics
        self.screens = screens
        self.card = BubbleCardPanel(contentRect: NSRect(origin: .zero, size: BubbleCardLayout.cardSize))
        super.init()

        card.delegate = self
        card.onCancel = { [weak self] in self?.collapse() }
        restoreCardSize()

        theater = BubbleTheaterController(
            card: card,
            pageBridge: pageBridge,
            hostScreen: { [weak self] in self?.physics.hostScreen ?? NSScreen.main ?? NSScreen() },
            isThreadShowing: { [weak self] in
                guard let self else { return false }
                return self.isExpanded && !self.showingPicker
            },
            onPushCardClip: { [weak self] in self?.pushCardClip() },
            onDidEnter: { [weak self] in
                self?.onPromoteOverlayStack()
                self?.onWake()
            },
            onDidExitRestored: { [weak self] in
                guard let self, self.isExpanded else { return }
                self.positionCard()
                self.onPromoteOverlayStack()
                self.onWake()
            }
        )

        // Only the URL is observed: the navigation and UI delegates stay with
        // the main controller, so downloads, offline handling and the
        // notification bridge keep working identically in bubble mode.
        webView.addObserver(self, forKeyPath: "URL", options: [.new], context: nil)
        observingURL = true
    }

    deinit { releaseWebView() }

    func releaseWebView() {
        if observingURL {
            webView.removeObserver(self, forKeyPath: "URL")
            observingURL = false
        }
        webView.removeFromSuperview()
    }

    func dismiss() {
        releaseWebView()
        theater.stopPolling()
        tether.hide()
        fixupLadder.cancel()
        scrollLadder.cancel()
        cancelPendingCollapse()
        card.orderOut(nil)
    }

    func cancelPendingCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    func markRedockedAfterDrag() {
        isExpanded = true
        card.orderFrontRegardless()
    }

    func setModalPresentationActive(_ active: Bool) {
        attachmentPickerActive = active
        if active {
            cancelPendingCollapse()
            return
        }
        guard isExpanded else { return }
        onPromoteOverlayStack()
        card.makeKey()
    }

    // MARK: Open / collapse

    /// Show a conversation (or the native picker when `convo == nil`) in the shared card.
    func open(_ convo: BubbleConversation?, toggle: Bool = true) {
        cancelPendingCollapse()
        PlumeTrace.log("\n===== open(\(convo?.name ?? "APP")) =====")
        #if DEBUG   // the log line is a no-op in release, the loop around it is not
        for (i, sc) in NSScreen.screens.enumerated() {
            PlumeTrace.log("  screen[\(i)] frame=\(PlumeTrace.r(sc.frame)) visible=\(PlumeTrace.r(sc.visibleFrame))")
        }
        #endif
        PlumeTrace.log("  mouse=\(PlumeTrace.p(NSEvent.mouseLocation)) main=\(PlumeTrace.r(NSScreen.main?.frame ?? .zero))")
        PlumeTrace.log("  panel[0].frame=\(PlumeTrace.r(physics.store.heads.first?.panel.frame ?? .zero)) panel[0].screen=\(PlumeTrace.r(physics.store.heads.first?.panel.screen?.frame ?? .zero))")
        let lastIdx = physics.store.lastOpenedIndex
        PlumeTrace.log("  lastOpened=\(lastIdx) panel[i].frame=\(PlumeTrace.r(physics.store.indices.contains(lastIdx) ? physics.store[lastIdx].panel.frame : .zero))")
        PlumeTrace.log("  centres[0] TRƯỚC sync=\(PlumeTrace.p(physics.store.heads.first?.centre ?? .zero))")

        // Before anything is placed relative to a bubble: find out where the
        // bubbles really are, and follow the user to the display they are on.
        physics.syncCentresFromPanels()
        PlumeTrace.log("  centres[0] SAU sync=\(PlumeTrace.p(physics.store.heads.first?.centre ?? .zero))")
        physics.adoptScreenUnderCursor()
        PlumeTrace.log("  centres[0] SAU adopt=\(PlumeTrace.p(physics.store.heads.first?.centre ?? .zero)) anchorTarget=\(PlumeTrace.p(physics.anchorTarget))")
        PlumeTrace.log("  card TRƯỚC=\(PlumeTrace.r(card.frame)) cardScreen=\(PlumeTrace.r(card.screen?.frame ?? .zero)) visible=\(card.isVisible) docked=\(physics.docked)")

        // Same bubble twice = close it again. Compare with what the card is
        // ACTUALLY showing so a swipe-back or link inside the card does not
        // misread a re-click as dismiss.
        let live = ThreadURL.id(from: webView.url)
        if toggle, isExpanded, card.isVisible,
           (convo == nil && showingPicker) || (convo != nil && convo?.id == live) {
            collapse()
            return
        }

        if let convo {
            onPromoteConversation(convo)
            showThread(convo.url)
            onClearBadgeForConversation(convo.id)
        } else {
            showPicker()
        }

        // Place the card under the chain whenever it is appearing or the chain
        // changed display. While already docked on the same display, leave the
        // user's dragged position alone.
        let cardMid = NSPoint(x: card.frame.midX, y: card.frame.midY)
        if !card.isVisible || !physics.docked
            || screens.nearest(to: cardMid) !== screens.nearest(to: physics.store.heads.first?.centre ?? cardMid) {
            positionCard()
            PlumeTrace.log("  -> positionCard()")
        } else {
            keepCardOnScreen()
            PlumeTrace.log("  -> keepCardOnScreen()")
        }
        PlumeTrace.log("  card SAU=\(PlumeTrace.r(card.frame)) cardScreen=\(PlumeTrace.r(card.screen?.frame ?? .zero))")

        isExpanded = true
        physics.docked = true
        // Open-boost layout before the first docked frame, then land on packed
        // row slots immediately — otherwise every head piles onto rest-step X
        // while diameters are still animating and the row looks stacked.
        physics.applyHoverFromFocus()
        physics.snapHeadsToDockedRow()
        onWake()

        // A short fade + layer transform, deliberately not a window-frame
        // animation (which would re-lay-out the WKWebView on every frame).
        card.contentView?.layer?.removeAnimation(forKey: "plume.fold")
        card.contentView?.layer?.transform = CATransform3DIdentity
        card.alphaValue = 0
        onPromoteOverlayStack()
        card.makeKey()
        onScheduleOverlayPromote(true)

        if let layer = card.contentView?.layer {
            let f = card.frame
            let from = CATransform3D.plumeCentered(
                center: CGPoint(x: f.width / 2, y: f.height / 2), scale: 0.94)
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
        onRefreshUnreadFlags()
    }

    func collapse() {
        guard isExpanded else { return }
        cancelPendingCollapse()
        theater.stopPolling()
        if theater.isActive { theater.exit(restore: true) }
        isExpanded = false
        physics.docked = false
        physics.store.hoverFocus = nil
        pushCardClip()
        tether.hide()
        onWake()                              // the chain flies home to its column
        onOrderBubblesFront()
        onRefreshUnreadFlags()

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
            let to = CATransform3D.plumeCentered(
                center: CGPoint(x: f.width / 2, y: f.height / 2),
                scale: 0.08,
                translation: CGPoint(x: t.midX - f.midX, y: t.midY - f.midY)
            )
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

    private func shrinkTarget() -> NSRect {
        let i = min(max(physics.store.lastOpenedIndex, 0), max(0, physics.store.count - 1))
        let c = physics.store.indices.contains(i)
            ? physics.store[i].centre
            : NSPoint(x: card.frame.midX, y: card.frame.midY)
        let d = Chain.base
        return NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }

    // MARK: Thread & Picker content

    private func installContent(_ view: NSView) {
        guard let content = card.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.removeAnimation(forKey: "plume.fold")
        content.layer?.transform = CATransform3DIdentity
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate(view.pinEdges(to: content, inset: BubbleCardLayout.inset))
    }

    func pushCardClip() {
        let active = isExpanded && !showingPicker && webView.superview === card.contentView
        pageBridge.setCardThreadMode(active: active)
        if active {
            theater.startPolling()
        } else {
            theater.stopPolling()
            theater.exit(restore: false)
        }
    }

    private func showThread(_ url: URL) {
        showingPicker = false
        applyThreadSize()
        if card.isVisible { keepCardOnScreen() }
        installContent(webView)

        let alreadyOpen = ThreadURL.id(from: webView.url) == ThreadURL.id(from: url)
        // Patch helpers onto the live page first, then click the inbox row
        // before the card stylesheet hides it again.
        pageBridge.injectThreadHelpers { [weak self] in
            self?.openThreadInPage(url, force: alreadyOpen)
        }
    }

    private func openThreadInPage(_ url: URL, force: Bool) {
        guard let live = webView.url, Plume.isInternal(live) else {
            webView.load(URLRequest(url: url))
            settleCard()
            return
        }
        pageBridge.openThread(url: url, force: force) { [weak self] opened in
            guard let self else { return }
            // Never `load()` a thread URL on top of a live Messenger session:
            // a reload tears down the inbox and wipes every contact bubble.
            if !opened {
                // Off the messages pages (a Facebook profile or post opened
                // from a chat) there is no inbox to tear down and no row to click.
                if !ThreadURL.isMessagesSurface(self.webView.url) {
                    PlumeTrace.log("  openThread: off the messages pages, loading the thread")
                    self.webView.load(URLRequest(url: url))
                    self.settleCard()
                    return
                }
                PlumeTrace.log("  openThread: no row to click")
                let shown = ThreadURL.id(from: self.webView.url)
                if let i = self.physics.store.index(forID: shown) {
                    self.physics.store.lastOpenedIndex = i
                    self.onWake()
                }
            }
            self.settleCard()
        }
    }

    /// After a thread switch: re-hide the inbox, then let Messenger settle.
    private func settleCard() {
        pushCardClip()
        scheduleCardFixups()
        scheduleScrollToLatest()
    }

    func scheduleCardFixups() {
        fixupLadder.schedule(delays: Self.fixupDelays) { [weak self] _ in
            guard let self else { return }
            self.pageBridge.hideSkipLinks()
            self.pushCardClip()
        }
    }

    /// Ladder of scroll-to-end attempts: a new thread replaces the old ladder,
    /// and a thread already resting on its newest message ends it early.
    private func scheduleScrollToLatest() {
        var settled = 0
        scrollLadder.schedule(delays: Self.scrollDelays) { [weak self] gen in
            guard let self, self.isExpanded, !self.showingPicker else { return }
            self.pageBridge.scrollToLatest { [weak self] atEnd in
                guard let self, self.scrollLadder.generation == gen else { return }
                settled = atEnd ? settled + 1 : 0
                if settled >= 2 { self.scrollLadder.cancel() }
            }
        }
    }

    private func showPicker() {
        showingPicker = true
        pushCardClip()
        let size = BubbleCardLayout.pickerContentSize(
            visible: physics.hostScreen.visibleFrame, canvas: Chain.canvas)
        card.setContentSize(size)
        if card.isVisible { keepCardOnScreen() }

        listView.onPick = { [weak self] convo in
            guard let self else { return }
            self.onSpawnConversation(convo)
            self.physics.store.lastOpenedIndex = self.physics.store.index(forID: convo.id) ?? 0
            self.showThread(convo.url)
        }
        listView.onLoadMore = { [weak self] in self?.loadMorePicker() }
        listView.onDelete = { [weak self] convo in
            self?.pageBridge.deleteConversation(convo) { [weak self] deleted in
                guard let self, deleted else { return }
                self.onRemoveConversationHead(convo.id)
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

    private func refreshPicker(preserveScroll: Bool, expandFirst: Bool) {
        listView.setLoadMoreBusy(true)
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            let want = self.pickerLimit
            self.pageBridge.fetchConversations(limit: want) { [weak self] convos in
                guard let self else { return }
                let grew = convos.count > self.lastPickerCount
                if grew { self.pickerStalls = 0 }
                else if expandFirst { self.pickerStalls += 1 }
                self.lastPickerCount = convos.count
                let canMore = want < Self.pickerMax && self.pickerStalls < 2
                self.listView.set(convos, canLoadMore: canMore, preserveScroll: preserveScroll)
                self.listView.setLoadMoreBusy(false)
            }
        }
        guard expandFirst else { finish(); return }
        pageBridge.expandConversationList {
            // Give React a beat to mount the newly revealed rows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { finish() }
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

    // MARK: Positioning & Sizing

    func positionCard(promote: Bool = true) {
        let i = min(max(physics.store.lastOpenedIndex, 0), max(0, physics.store.count - 1))
        let head = physics.store.indices.contains(i)
            ? physics.store[i].centre
            : (physics.store.heads.first?.centre ?? NSPoint(x: card.frame.midX, y: card.frame.midY))
        let visible = screens.nearest(to: head).visibleFrame
        let size = card.frame.size
        let origin = BubbleCardLayout.cardOrigin(
            under: head, cardSize: size, visible: visible,
            canvas: Chain.canvas, peakDiameter: Chain.peak)
        let dest = NSRect(origin: origin, size: size)
        let destScreen = screens.nearest(to: NSPoint(x: dest.midX, y: dest.midY))
        PlumeTrace.log("  positionCard want=\(PlumeTrace.r(dest)) visible=\(PlumeTrace.r(visible)) destScreen=\(PlumeTrace.r(destScreen.frame))")

        // orderOut first when hopping displays so the panel drops its old screen association.
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
    func keepCardOnScreen() {
        let visible = screens.nearest(to: NSPoint(x: card.frame.midX, y: card.frame.midY)).visibleFrame
        let origin = BubbleCardLayout.clampedOrigin(
            card.frame.origin, cardSize: card.frame.size,
            visible: visible, peakDiameter: Chain.peak)
        guard abs(origin.x - card.frame.origin.x) > 0.5
                || abs(origin.y - card.frame.origin.y) > 0.5 else { return }
        card.setFrameOrigin(origin)
    }

    private func applyThreadSize() {
        let size = BubbleCardLayout.threadContentSize(
            saved: Preferences.bubbleCardSize, minSize: card.minSize,
            visible: physics.hostScreen.visibleFrame, peakDiameter: Chain.peak)
        if card.contentRect(forFrameRect: card.frame).size != size {
            card.setContentSize(size)
            scheduleCardFixups()      // new viewport, new chrome width
        }
    }

    private func restoreCardSize() {
        guard let saved = Preferences.bubbleCardSize else { return }
        let visible = physics.hostScreen.visibleFrame
        let size = NSSize(width: min(max(saved.width, card.minSize.width), visible.width),
                          height: min(max(saved.height, card.minSize.height), visible.height))
        card.setContentSize(size)
    }

    private func saveCardSize() {
        Preferences.bubbleCardSize = card.contentRect(forFrameRect: card.frame).size
    }

    func updateTether() {
        guard isExpanded, card.isVisible, !physics.store.isEmpty else {
            tether.hide(); return
        }
        let i = min(max(physics.store.lastOpenedIndex, 0), physics.store.count - 1)
        let head = physics.store[i]
        let d = max(head.diameter, Chain.base)
        let from = NSPoint(x: head.centre.x, y: head.centre.y - d / 2)
        let to = NSPoint(x: head.centre.x, y: min(card.frame.maxY - 2, from.y - 4))
        // Cord only when there is a visible gap between head and card.
        guard from.y > to.y + 2 else { tether.hide(); return }
        tether.update(from: from, to: to)
    }

    // MARK: NSWindowDelegate & URL KVO

    func windowDidMove(_ notification: Notification) {
        guard physics.docked else { return }
        keepCardOnScreen()      // the row hangs off the card's top edge
        onWake()
    }

    func windowDidResize(_ notification: Notification) {
        guard physics.docked else { return }
        keepCardOnScreen()
        onWake()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isExpanded else { return }
        guard !physics.dragging, !physics.cardTravelsWithChain, !relocatingCard else { return }
        guard !attachmentPickerActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded, !self.card.isKeyWindow else { return }
            guard !self.physics.dragging, !self.physics.cardTravelsWithChain else { return }
            guard !self.attachmentPickerActive else { return }
            self.collapse()
        }
        collapseWork?.cancel()
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        cancelPendingCollapse()
        // Becoming key can demote a nonactivating panel relative to fullscreen
        // peers — re-assert the same overlay stack the bubbles already keep.
        if isExpanded { onPromoteOverlayStack() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !showingPicker, !theater.isActive else { return }
        saveCardSize()
        scheduleCardFixups()
    }

    /// Messenger routes between threads without a navigation, so this is the
    /// only signal the card gets that the page moved.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "URL", isExpanded { scheduleCardFixups() }
    }
}
