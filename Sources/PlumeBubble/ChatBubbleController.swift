import AppKit
import PlumeCore
import PlumeUI

/// Android-style chat heads: one bubble per conversation, each showing that
/// contact's avatar, all sharing a single card and a single web view so the
/// memory cost stays flat no matter how many bubbles are on screen.
///
/// Coordinates `BubbleChainPhysics`, `BubbleCardCoordinator`,
/// `BubbleOverlayMonitor`, `BubbleChipMenuPresenter` and `BubbleFrameDriver`,
/// and registers itself as `PlumeOverlay.activeHost` while open.
public final class ChatBubbleController: NSObject, OverlayHost {

    public static private(set) var shared: ChatBubbleController?
    public static var isOpen: Bool { shared != nil }

    /// Called when the user asks to leave bubble mode.
    private var onExitBubbleMode: (() -> Void)?

    /// Enter bubble mode with a snapshot of the user's conversations and a
    /// bridge to the shared Messenger web view.
    @discardableResult
    public static func show(conversations: [BubbleConversation],
                            bridge: BubblePageBridge,
                            onExit: @escaping () -> Void) -> ChatBubbleController {
        if let existing = shared { return existing }
        let c = ChatBubbleController(bridge: bridge, onExit: onExit)
        shared = c
        PlumeOverlay.activeHost = c
        c.build(conversations)
        return c
    }

    public static func hide() {
        PlumeOverlay.activeHost = nil
        shared?.dismiss()
        shared = nil
    }

    private let pageBridge: BubblePageBridge
    private let screens = ScreenResolver()
    private let physics: BubbleChainPhysics
    private let cardCoordinator: BubbleCardCoordinator
    private let monitor: BubbleOverlayMonitor
    private let chipMenu = BubbleChipMenuPresenter()
    private let overlayPromoteLadder = DelayedLadder()

    /// The frame clock; see `BubbleFrameDriver`. Calls back weakly.
    private var link: BubbleFrameDriver?
    private var linkScreen: NSScreen?
    private var lastFrame: CFTimeInterval = 0      // 0 = sentinel, not a timestamp
    private var idleFrames = 0

    /// Last total seen, so a rebuilt app chip keeps its badge across size changes.
    private var unreadTotal = 0
    private var unreadWork: DispatchWorkItem?

    private init(bridge: BubblePageBridge, onExit: @escaping () -> Void) {
        self.pageBridge = bridge
        self.onExitBubbleMode = onExit
        self.physics = BubbleChainPhysics(screens: screens)
        self.cardCoordinator = BubbleCardCoordinator(pageBridge: bridge, physics: physics, screens: screens)
        self.monitor = BubbleOverlayMonitor(screens: screens)
        super.init()
        wireCollaborators()
    }

    deinit {
        cardCoordinator.releaseWebView()
    }

    // MARK: OverlayHost

    public var sheetHost: NSWindow? { cardCoordinator.sheetHost }

    public func setModalPresentationActive(_ active: Bool) {
        cardCoordinator.setModalPresentationActive(active)
    }

    // MARK: Collaborator wiring

    private func wireCollaborators() {
        physics.cardFrame = { [weak self] in self?.cardCoordinator.card.frame ?? .zero }
        physics.isCardVisible = { [weak self] in self?.cardCoordinator.card.isVisible ?? false }
        physics.onBeforeUndockForDrag = { [weak self] in self?.cardCoordinator.cancelPendingCollapse() }
        physics.onPositionCard = { [weak self] promote in self?.cardCoordinator.positionCard(promote: promote) }
        physics.onOrderCardFront = { [weak self] in self?.cardCoordinator.card.orderFrontRegardless() }
        physics.onCardRedocked = { [weak self] in self?.cardCoordinator.markRedockedAfterDrag() }
        physics.onWake = { [weak self] in self?.wake() }
        physics.onResetForeignScreenTicks = { [weak self] in self?.monitor.resetForeignScreenTicks() }

        cardCoordinator.onPromoteOverlayStack = { [weak self] in self?.promoteOverlayStack() }
        cardCoordinator.onScheduleOverlayPromote = { [weak self] expandedOnly in
            self?.scheduleOverlayPromote(whileExpandedOnly: expandedOnly)
        }
        cardCoordinator.onWake = { [weak self] in self?.wake() }
        cardCoordinator.onRefreshUnreadFlags = { [weak self] in self?.refreshUnreadFlags() }
        cardCoordinator.onPromoteConversation = { [weak self] convo in
            guard let self, let i = self.physics.store.index(forID: convo.id), i != 1 else { return }
            self.physics.store.move(from: i, to: 1)
            self.physics.store.lastOpenedIndex = 1
        }
        cardCoordinator.onSpawnConversation = { [weak self] convo in self?.spawnBubble(for: convo) }
        cardCoordinator.onRemoveConversationHead = { [weak self] id in
            guard let self, let i = self.physics.store.index(forID: id), i > 0 else { return }
            self.removeBubble(at: i)
            self.wake()
        }
        cardCoordinator.onClearBadgeForConversation = { [weak self] id in
            guard let self, let i = self.physics.store.index(forID: id) else { return }
            self.physics.chip(of: self.physics.store[i].panel)?.setBadge(nil)
        }
        cardCoordinator.onOrderBubblesFront = { [weak self] in
            self?.physics.store.heads.forEach { $0.panel.orderFrontRegardless() }
        }

        monitor.isDragging = { [weak self] in self?.physics.dragging ?? false }
        monitor.headCentre = { [weak self] in self?.physics.store.heads.first?.centre }
        monitor.isAppChipHit = { [weak self] p in self?.isAppChipHit(atScreenPoint: p) ?? false }
        monitor.onAppChipRightClick = { [weak self] _ in
            guard let self, !self.physics.store.isEmpty else { return }
            self.chipMenu.showFromMonitor { self.cardCoordinator.cancelPendingCollapse() }
        }
        monitor.onDragMove = { [weak self] p in self?.physics.dragTo(p) }
        monitor.onDragEndFromMonitor = { [weak self] _ in self?.physics.endDragUsingRecordedSamples() }
        monitor.onDragEndFromPoll = { [weak self] _ in self?.physics.endDragUsingRecordedSamples() }
        monitor.onHoverUpdate = { [weak self] p in
            guard let self else { return }
            if self.physics.updateHover(at: p) { self.wake() }
        }
        monitor.onSyncClickThrough = { [weak self] in self?.physics.syncBubbleClickThrough() }
        monitor.onFollowCursorToScreen = { [weak self] target in
            guard let self else { return }
            if self.physics.teleportChain(to: target, reason: "follow-cursor") {
                if self.cardCoordinator.card.isVisible {
                    self.cardCoordinator.positionCard()
                    self.promoteOverlayStack()
                }
                self.wake()
            }
        }
        monitor.onOverlayKeepAlive = { [weak self] in self?.promoteOverlayStack() }

        chipMenu.onExitBubbleMode = { [weak self] in self?.onExitBubbleMode?() }
        chipMenu.onPickLimit = { [weak self] limit in
            Preferences.bubbleLimit = limit
            self?.applyBubbleLimit()
        }
        chipMenu.onPickSize = { [weak self] size in
            guard size != Preferences.bubbleSize else { return }
            Preferences.bubbleSize = size
            self?.rebuildChain()
        }
        chipMenu.onPickFollowDisplay = { [weak self] follow in
            Preferences.bubbleFollowActiveDisplay = follow
            self?.monitor.resetForeignScreenTicks()
        }
    }

    // MARK: Build & Chain Lifecycle

    private func build(_ conversations: [BubbleConversation]) {
        // App chip heads the chain, then contacts newest → oldest, capped by setting.
        let capped = Array(conversations.prefix(Preferences.bubbleLimit))
        let entries: [BubbleConversation?] = [nil] + capped.map { $0 }
        let head = physics.savedHeadCentre()
        for (i, convo) in entries.enumerated() {
            appendBubble(convo, centre: NSPoint(x: head.x, y: head.y - CGFloat(i) * Chain.step),
                         adjustIndices: false)
        }
        physics.store.anchorIndex = 0
        physics.anchorTarget = physics.clampedAnchor(head)
        monitor.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(unreadChanged(_:)),
            name: .plumeUnreadChanged, object: nil)
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
    private func appendBubble(_ convo: BubbleConversation?,
                              centre: NSPoint,
                              at index: Int? = nil,
                              adjustIndices: Bool = true) {
        let chip = BubbleChipView(conversation: convo)
        chip.setDiameter(0)          // the pop-in starts from nothing
        let panel = BubblePanel(size: Chain.canvas)
        panel.contentView = chip

        // Weak on `panel` as well as `self`: the panel owns the chip, so a
        // strong capture here closes a cycle and leaks every retired head.
        chip.onClick = { [weak self, weak panel] c in
            guard let self, let panel else { return }
            self.physics.store.lastOpenedIndex = self.physics.index(of: panel) ?? 0
            self.cardCoordinator.open(c)
        }
        chip.onDragBegan = { [weak self, weak panel] grab in
            guard let panel else { return }
            self?.physics.beginDrag(panel, grab: grab)
        }
        chip.onDragTo = { [weak self] cursor in self?.physics.dragTo(cursor) }
        chip.onDragEnded = { [weak self] v in self?.physics.endDrag(velocity: v) }
        if convo == nil {   // the app chip carries the app-level gestures
            chip.onDoubleClick = { [weak self] in self?.onExitBubbleMode?() }
            chip.onSecondaryClick = { [weak self] in self?.chipMenu.show() }
        }

        let targetIdx = index.map { min($0, physics.store.count) } ?? physics.store.count
        let head = BubbleHead(
            panel: panel,
            conversationID: convo?.id,
            centre: centre,
            velocity: .zero,
            diameter: 0,
            hoverTarget: Chain.base,
            born: CACurrentMediaTime() + Double(targetIdx) * 0.045
        )
        physics.store.insert(head, at: targetIdx, adjustTrackedIndices: adjustIndices)

        panel.setFrameOrigin(NSPoint(x: centre.x - Chain.canvas / 2,
                                     y: centre.y - Chain.canvas / 2))
        PlumeOverlay.apply(to: panel)
        panel.orderFrontRegardless()
    }

    /// Ordering a panel out releases nothing (`isReleasedWhenClosed` is false),
    /// so retire it explicitly.
    private func retire(_ panel: BubblePanel) {
        if let chip = physics.chip(of: panel) {
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

    private func removeBubble(at i: Int) {
        if let removed = physics.store.remove(at: i) {
            retire(removed.panel)
        }
    }

    private func clearChainState(keepingPinned: Bool = true) {
        physics.store.heads.forEach { retire($0.panel) }
        physics.store.removeAll(keepingPinned: keepingPinned)
    }

    private func conversation(at index: Int) -> BubbleConversation? {
        guard physics.store.indices.contains(index) else { return nil }
        return physics.chip(of: physics.store[index].panel)?.conversation
    }

    /// A panel's canvas is fixed at creation, so a new size means new panels.
    /// The conversations, their order and the chain's anchor all survive.
    private func rebuildChain() {
        let convos = physics.store.heads.dropFirst().compactMap { physics.chip(of: $0.panel)?.conversation }
        let head = physics.store.heads.first?.centre ?? physics.savedHeadCentre()
        clearChainState(keepingPinned: true)
        for (i, convo) in ([nil] + convos.map { Optional($0) }).enumerated() {
            appendBubble(convo, centre: NSPoint(x: head.x, y: head.y - CGFloat(i) * Chain.step),
                         adjustIndices: false)
        }
        physics.store.anchorIndex = 0
        physics.anchorTarget = physics.clampedAnchor(head)
        wake()
        applyTotalBadge()
        refreshUnreadFlags()      // new chips start from the stored snapshot
    }

    /// Trim the chain to the current limit. Contacts are heads[1...], oldest
    /// last. Called from both menus that offer the setting.
    public func applyBubbleLimit() {
        while physics.store.contactCount > Preferences.bubbleLimit, physics.store.count > 1 {
            removeBubble(at: physics.store.count - 1)
        }
        physics.anchorTarget = physics.clampedAnchor(physics.anchorTarget, index: physics.store.anchorIndex)
        wake()
    }

    /// Picking from the app chip's list earns that contact its own head.
    private func spawnBubble(for convo: BubbleConversation) {
        physics.store.pinnedIDs.insert(convo.id)
        if let existing = physics.store.index(forID: convo.id) {
            if existing != 1 { physics.store.move(from: existing, to: 1) }
            return
        }
        if physics.store.contactCount >= Preferences.bubbleLimit, physics.store.count > 1 {
            removeBubble(at: physics.store.count - 1)
        }
        let centre = physics.store.heads.first.map {
            NSPoint(x: $0.centre.x, y: $0.centre.y - Chain.step)
        } ?? physics.savedHeadCentre()
        appendBubble(convo, centre: centre, at: 1, adjustIndices: true)
        physics.anchorTarget = physics.clampedAnchor(physics.anchorTarget, index: physics.store.anchorIndex)
        wake()
    }

    private func dismiss() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        unreadWork?.cancel(); unreadWork = nil
        overlayPromoteLadder.cancel()
        physics.docked = false
        teardownLoop()
        cardCoordinator.dismiss()
        clearChainState(keepingPinned: false)
    }

    // MARK: Unread badges & chain sync

    private func applyTotalBadge() {
        physics.store.heads.first.flatMap { physics.chip(of: $0.panel) }?
            .setBadge(UnreadBadge.label(unreadTotal, hidden: Preferences.hideUnreadCount))
    }

    @objc private func unreadChanged(_ note: Notification) {
        unreadTotal = PlumeUnreadNotification.count(from: note)
        applyTotalBadge()
        // The title changes in bursts while a conversation updates; one snapshot
        // after the burst is worth the same as ten during it.
        unreadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshUnreadFlags() }
        unreadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Refresh per-contact unread dots and reorder the chain to match
    /// Messenger's newest-first inbox snapshot.
    private func refreshUnreadFlags() {
        pageBridge.fetchConversations(limit: max(Preferences.bubbleLimit * 3, 12)) { [weak self] convos in
            guard let self else { return }
            let inboxHidden = self.cardCoordinator.isExpanded && !self.cardCoordinator.showingPicker
            guard BubbleChainSync.shouldApplySnapshot(
                count: convos.count, contactHeads: self.physics.store.contactCount, inboxHidden: inboxHidden)
            else { return }
            let unread = Set(convos.filter(\.unread).map(\.id))
            for head in self.physics.store.heads {
                guard let chip = self.physics.chip(of: head.panel), let convo = chip.conversation else { continue }
                chip.setBadge(unread.contains(convo.id) ? "" : nil)
            }
            self.syncChainToRecents(convos)
        }
    }

    /// Match the contact chain to Messenger's newest-first list, keeping
    /// picker-pinned heads. Index 0 (app chip) never moves. Skipped mid-drag.
    private func syncChainToRecents(_ convos: [BubbleConversation]) {
        guard !physics.dragging, !physics.store.isEmpty else { return }
        let recents = convos.map(\.id)
        var byID: [String: BubbleConversation] = [:]
        for convo in convos where byID[convo.id] == nil { byID[convo.id] = convo }
        let desired = BubbleChainSync.merge(
            current: physics.store.heads.dropFirst().compactMap(\.conversationID),
            recents: recents,
            pinned: physics.store.pinnedIDs,
            limit: Preferences.bubbleLimit
        )
        // A picked thread that has become recent is an ordinary head again.
        physics.store.pinnedIDs.subtract(
            BubbleChainSync.recentWindow(recents, limit: Preferences.bubbleLimit))

        // Drop contact heads the snapshot no longer wants.
        for i in stride(from: physics.store.count - 1, through: 1, by: -1) {
            guard let id = physics.store[i].conversationID, !desired.contains(id) else { continue }
            removeBubble(at: i)
        }

        // Ensure each wanted head exists at its rank (1 = newest).
        for (rank, id) in desired.enumerated() {
            let target = rank + 1
            if let existing = physics.store.index(forID: id) {
                if existing != target { physics.store.move(from: existing, to: target) }
            } else if let convo = byID[id] {
                let insertAt = min(target, physics.store.count)
                let fallbackIdx = min(insertAt, max(0, physics.store.count - 1))
                let centre = physics.store.indices.contains(fallbackIdx)
                    ? physics.store[fallbackIdx].centre
                    : (physics.store.heads.first?.centre ?? physics.savedHeadCentre())
                appendBubble(convo, centre: centre, at: insertAt, adjustIndices: true)
            }
        }
        physics.anchorTarget = physics.clampedAnchor(physics.anchorTarget, index: physics.store.anchorIndex)
        wake()
    }

    // MARK: Shortcut & Notification Entry Points

    /// The menu bar icon or the global shortcut, in bubble mode: fold the card
    /// away if it is open, else unfold it on the conversation the page is on
    /// (or the list). Never the main window: it is hidden on purpose here.
    public func toggleCardFromShortcut() {
        if cardCoordinator.isExpanded, cardCoordinator.card.isVisible {
            cardCoordinator.collapse()
            return
        }
        openResolvedThread(ThreadURL.canonical(from: pageBridge.webView.url))
    }

    /// A native notification was clicked. `activate` replays the click in the
    /// page, which routes Messenger to that conversation; the card then opens
    /// on wherever the page landed — never the main window, never NSApp.activate.
    public func openFromNotification(_ activate: (@escaping (Bool) -> Void) -> Void) {
        let before = ThreadURL.canonical(from: pageBridge.webView.url)
        activate { [weak self] known in
            guard let self else { return }
            guard known else {
                // The page has forgotten it (reloaded since): offer the list.
                if !(self.cardCoordinator.isExpanded && self.cardCoordinator.showingPicker) {
                    self.physics.store.lastOpenedIndex = 0
                    self.cardCoordinator.open(nil)
                }
                return
            }
            self.awaitNotificationThread(from: before, tries: 8)
        }
    }

    private func awaitNotificationThread(from before: URL?, tries: Int) {
        let now = ThreadURL.canonical(from: pageBridge.webView.url)
        if tries > 0, now == nil || now == before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.awaitNotificationThread(from: before, tries: tries - 1)
            }
            return
        }
        guard !physics.store.isEmpty else { return }
        guard let thread = now else {
            if !(cardCoordinator.isExpanded && cardCoordinator.showingPicker) {
                physics.store.lastOpenedIndex = 0
                cardCoordinator.open(nil)
            }
            return
        }
        // Already showing it: `open` would read that as "same bubble twice"
        // and fold the card away.
        if cardCoordinator.isExpanded, cardCoordinator.card.isVisible, !cardCoordinator.showingPicker {
            if let i = physics.store.index(forID: ThreadURL.id(from: thread)) {
                physics.store.lastOpenedIndex = i
                wake()
            }
            promoteOverlayStack()
            cardCoordinator.card.makeKey()
            return
        }
        openResolvedThread(thread)
    }

    /// Open `thread` using its existing bubble head if present, a transient
    /// conversation wrapper if headless, or the picker when `thread` is nil.
    private func openResolvedThread(_ thread: URL?) {
        if let thread, let i = physics.store.index(forID: ThreadURL.id(from: thread)),
           let convo = conversation(at: i) {
            physics.store.lastOpenedIndex = i
            cardCoordinator.open(convo, toggle: false)
        } else if let thread {
            physics.store.lastOpenedIndex = 0
            cardCoordinator.open(BubbleConversation(thread: thread), toggle: false)
        } else {
            physics.store.lastOpenedIndex = 0
            cardCoordinator.open(nil, toggle: false)
        }
    }

    // MARK: Overlay stacking, Space & Screen events

    private func isAppChipHit(atScreenPoint screenPoint: NSPoint) -> Bool {
        guard let head = physics.store.heads.first else { return false }
        // Prefer the live panel frame — model centre can lag a commit behind.
        let c = NSPoint(x: head.panel.frame.midX, y: head.panel.frame.midY)
        let r = max(head.diameter, Chain.base) / 2 + 6
        return hypot(screenPoint.x - c.x, screenPoint.y - c.y) <= r
    }

    @objc private func screensChanged() {
        guard !physics.store.isEmpty, !NSScreen.screens.isEmpty else { return }
        physics.anchorTarget = physics.clampedAnchor(physics.anchorTarget, index: physics.store.anchorIndex)
        if cardCoordinator.card.isVisible { cardCoordinator.keepCardOnScreen() }
        promoteOverlayStack()
        wake()
    }

    @objc private func activeSpaceChanged() {
        // Mission Control settles over several hundred ms; re-pin on a ladder.
        scheduleOverlayPromote()
    }

    /// Pin card + heads above fullscreen app content. Bubbles stay above the
    /// card so the docked row remains clickable.
    private func promoteOverlayStack() {
        let card = cardCoordinator.card
        let tether = cardCoordinator.tether
        PlumeOverlay.apply(to: card)
        PlumeOverlay.apply(to: tether)
        for head in physics.store.heads {
            PlumeOverlay.apply(to: head.panel)
        }
        if card.isVisible || cardCoordinator.isExpanded {
            card.orderFrontRegardless()
        }
        if tether.isVisible {
            tether.orderFrontRegardless()
        }
        for head in physics.store.heads {
            head.panel.orderFrontRegardless()
        }
    }

    private func scheduleOverlayPromote(whileExpandedOnly: Bool = false) {
        overlayPromoteLadder.schedule(delays: [0.0, 0.05, 0.2, 0.5, 1.0, 2.0]) { [weak self] _ in
            guard let self, !self.physics.store.isEmpty else { return }
            if whileExpandedOnly, !self.cardCoordinator.isExpanded { return }
            self.promoteOverlayStack()
        }
    }

    // MARK: Frame loop

    private func wake() {
        guard !physics.store.isEmpty else { return }
        if link == nil || link?.isPaused == true { physics.syncCentresFromPanels() }
        idleFrames = 0
        if let link, linkScreen === physics.anchorScreen {
            if link.isPaused { lastFrame = 0; link.isPaused = false }
            return
        }
        arm(on: physics.anchorScreen)
    }

    private func arm(on screen: NSScreen) {
        link?.invalidate()
        link = BubbleFrameDriverFactory.make(screen: screen) { [weak self] now, nominal in
            self?.tick(now: now, nominal: nominal)
        }
        lastFrame = 0
        linkScreen = screen
    }

    private func park() {
        link?.isPaused = true
        lastFrame = 0
    }

    private func teardownLoop() {
        link?.invalidate(); link = nil
        linkScreen = nil
        monitor.stop()
    }

    private func tick(now: CFTimeInterval, nominal: CFTimeInterval) {
        guard !physics.store.isEmpty, !NSScreen.screens.isEmpty else { park(); return }

        let raw = lastFrame == 0 ? nominal : now - lastFrame
        lastFrame = now
        let dt = CGFloat(min(max(raw, Double(Chain.dtMin)), Double(Chain.dtMax)))

        physics.applyHoverFromFocus()
        var moving = physics.integrate(dt: dt, now: now)
        moving = physics.advanceMagnification(dt: dt) || moving
        physics.commit()
        if physics.docked, cardCoordinator.card.isVisible { cardCoordinator.updateTether() }

        // Card rides the chain for the whole drag; promote only on display hop.
        if physics.cardTravelsWithChain, cardCoordinator.card.isVisible {
            let prevScreen = physics.lastCardTravelScreen
            cardCoordinator.positionCard(promote: false)
            if let head = physics.store.heads.first?.centre {
                let s = screens.nearest(to: head)
                physics.lastCardTravelScreen = s
                if s !== prevScreen { cardCoordinator.card.orderFrontRegardless() }
            }
            moving = true
        }

        if moving {
            idleFrames = 0
        } else {
            idleFrames += 1
            if idleFrames > 2 {
                physics.snapToRest(anchor: min(physics.store.anchorIndex, physics.store.count - 1))
                park()
            }
        }
        if linkScreen !== physics.anchorScreen { arm(on: physics.anchorScreen) }
    }
}
