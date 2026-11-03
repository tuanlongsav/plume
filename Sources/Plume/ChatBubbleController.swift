import AppKit
import WebKit

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
    // Bumped: the previous key holds sizes produced by an auto-widen that has
    // since been removed, and those are not sizes anyone chose.

    private let card: BubbleCardPanel
    private let tether = BubbleTetherPanel()
    private var bubbles: [BubblePanel] = []
    private var webView: WKWebView!
    private var isExpanded = false
    private var showingPicker = false
    /// Heads the user opened from the picker. They stay in the chain even
    /// when the thread is older than the recents window (`BubbleChainSync`).
    private var pinnedIDs: Set<String> = []
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
            chip.onSecondaryClick = { [weak self] in self?.showChipMenu() }
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
        // Mid-reconfiguration the list can be briefly empty; the notification
        // fires again once a display is back.
        guard !bubbles.isEmpty, !NSScreen.screens.isEmpty else { return }
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
            .setBadge(WebViewController.badgeLabel(unreadTotal))
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
            let unread = Set(convos.filter(\.unread).map(\.id))
            for panel in self.bubbles {
                guard let chip = self.chip(panel), let convo = chip.conversation else { continue }
                chip.setBadge(unread.contains(convo.id) ? "" : nil)
            }
            self.syncChainToRecents(convos)
        }
    }

    private func conversation(of panel: BubblePanel) -> BubbleConversation? {
        chip(panel)?.conversation
    }

    /// The head showing conversation `id`. A nil id matches the app chip,
    /// which carries no conversation.
    private func headIndex(for id: String?) -> Int? {
        bubbles.firstIndex { conversation(of: $0)?.id == id }
    }

    /// Match the contact chain to Messenger's newest-first list, keeping the
    /// heads the user opened from the picker. Index 0 (app chip) never moves.
    /// Skipped mid-drag so the gesture keeps its grab.
    private func syncChainToRecents(_ convos: [BubbleConversation]) {
        guard !dragging, !bubbles.isEmpty else { return }
        let contacts = max(0, bubbles.count - 1)
        let inboxHidden = isExpanded && !showingPicker
        guard BubbleChainSync.shouldApplySnapshot(
            count: convos.count, contactHeads: contacts, inboxHidden: inboxHidden)
        else { return }
        let recents = convos.map(\.id)
        var byID: [String: BubbleConversation] = [:]
        for convo in convos where byID[convo.id] == nil { byID[convo.id] = convo }
        let desired = BubbleChainSync.merge(
            current: bubbles.dropFirst().compactMap { conversation(of: $0)?.id },
            recents: recents, pinned: pinnedIDs, limit: Preferences.bubbleLimit)
        // A picked thread that has become recent is an ordinary head again.
        pinnedIDs.subtract(BubbleChainSync.recentWindow(recents, limit: Preferences.bubbleLimit))

        // Drop contact heads the snapshot no longer wants.
        for i in stride(from: bubbles.count - 1, through: 1, by: -1) {
            guard let id = conversation(of: bubbles[i])?.id, !desired.contains(id) else { continue }
            adjustIndicesAfterRemoval(i)
            removeBubble(at: i)
        }

        // Ensure each wanted head exists at its rank (1 = newest). Everything
        // left is in `desired`, so the chain is already within the limit.
        for (rank, id) in desired.enumerated() {
            let target = rank + 1
            if let existing = headIndex(for: id) {
                if existing != target { moveBubble(from: existing, to: target) }
            } else if let convo = byID[id] {
                let insertAt = min(target, bubbles.count)
                let centre = centres.indices.contains(min(insertAt, max(0, centres.count - 1)))
                    ? centres[min(insertAt, centres.count - 1)]
                    : (centres.first ?? savedHeadCentre())
                appendBubble(convo, centre: centre, at: insertAt)
                adjustIndicesAfterInsertion(insertAt)
            }
        }
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        wake()
    }

    private func adjustIndicesAfterInsertion(_ i: Int) {
        if anchorIndex >= i { anchorIndex += 1 }
        if lastOpenedIndex >= i { lastOpenedIndex += 1 }
        if let focus = hoverFocus, focus >= i { hoverFocus = focus + 1 }
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
        pinnedIDs.insert(convo.id)
        if let existing = headIndex(for: convo.id) {
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
        adjustIndicesAfterInsertion(1)
        // One more head means one more `step` of room the chain needs; without
        // this the tail is pinned at the screen edge and never reaches rest.
        anchorTarget = clampedAnchor(anchorTarget, index: anchorIndex)
        wake()
    }

    /// Retire every head and empty the arrays that run parallel to them.
    private func clearChainState() {
        bubbles.forEach(retire)
        bubbles.removeAll()
        centres.removeAll(); velocities.removeAll()
        diameters.removeAll(); hoverTargets.removeAll(); born.removeAll()
    }

    private func removeBubble(at i: Int) {
        guard bubbles.indices.contains(i) else { return }
        if let id = conversation(of: bubbles[i])?.id { pinnedIDs.remove(id) }
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

    /// Put `view` in the card with an even margin on every side. Messenger's
    /// chrome columns are hidden by `cardThreadCSS` (see `pushCardClip`), not
    /// clipped, so the web view gets the same margins as everything else.
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
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
        ])
    }

    /// When Messenger's photo theatre opens, expand the card to nearly fill the
    /// display — theatre centres on the full page, so only a wide window lays
    /// it out correctly.
    private var theaterMode = false
    private var preTheaterSize: NSSize?
    /// Debounce theatre open/close so a one-frame DOM blip cannot thrash size.
    private var theaterOpenTicks = 0
    private var theaterCloseTicks = 0
    /// Right after expanding, theatre may still be re-laying out — do not
    /// restore the small card until this deadline (or until it is seen, then lost).
    private var theaterHoldUntil: CFTimeInterval = 0
    private var theaterPollTimer: Timer?
    private var overlayPromoteWork: [DispatchWorkItem] = []

    /// Encoded once: this runs ~9 times per thread open.
    private static let cardThreadCSSJSON =
        InjectedScript.stringLiteral(InjectedScript.cardThreadCSS) ?? "\"\""

    private func pushCardClip() {
        guard webView != nil else { return }
        let active = isExpanded && !showingPicker
            && webView.superview === card.contentView
        let js = """
        try {
          document.documentElement.classList.toggle("plume-card-thread", \(active ? "true" : "false"));
        } catch (e) {}
        if (\(active ? "true" : "false")) {
          window.__plumeSetStyle && window.__plumeSetStyle("\(InjectedScript.StyleID.cardThread)", \(Self.cardThreadCSSJSON));
        } else {
          window.__plumeRemoveStyle && window.__plumeRemoveStyle("\(InjectedScript.StyleID.cardThread)");
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        if active {
            startTheaterPoll()
        } else {
            stopTheaterPoll()
            exitTheaterMode(restore: false)
        }
    }

    /// Poll theatre open/close while a thread is showing in the card.
    private func startTheaterPoll() {
        guard theaterPollTimer == nil else { return }
        let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self, self.isExpanded, !self.showingPicker else { return }
            // Covered or on another Space: nobody can open a photo in it, and
            // each detect pass walks every image in the page.
            guard self.card.occlusionState.contains(.visible) else { return }
            self.pollTheaterMode()
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        theaterPollTimer = t
    }

    private func stopTheaterPoll() {
        theaterPollTimer?.invalidate()
        theaterPollTimer = nil
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

        pushCardClip()

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
        pushCardClip()
        if restore, isExpanded, card.isVisible {
            positionCard()
            promoteOverlayStack()
            wake()
        }
    }

    private func saveCardSize() {
        Preferences.bubbleCardSize = card.contentRect(forFrameRect: card.frame).size
    }

    @objc private func exitBubbleMode() { onExitBubbleMode?() }

    /// Right-click on the app chip. Everything that would otherwise need chrome
    /// glued over the card lives here instead, so the card stays nothing but
    /// the conversation.
    private func showChipMenu() {
        let menu = NSMenu()
        // Bubbles sit at `.screenSaver`; AppKit's default menu window is only
        // `.popUpMenu` (~101) and opens *under* the chain — looks like right-
        // click does nothing. Elevate tracking menus to our overlay tier.
        menu.delegate = ChipMenuLift.shared

        let back = NSMenuItem(title: L.t("Về cửa sổ chính", "Back to Main Window"),
                              action: #selector(exitBubbleMode), keyEquivalent: "")
        back.target = self
        back.image = Self.menuSymbol("macwindow")
        menu.addItem(back)
        menu.addItem(.separator())

        let limits = Self.bubbleLimitMenu(target: self, action: #selector(pickLimit(_:)))
        limits.delegate = ChipMenuLift.shared
        let limitItem = NSMenuItem(title: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                   action: nil, keyEquivalent: "")
        limitItem.image = Self.menuSymbol("circle.grid.2x2")
        limitItem.submenu = limits
        menu.addItem(limitItem)

        let sizes = NSMenu()
        sizes.delegate = ChipMenuLift.shared
        for choice in Preferences.bubbleSizeChoices {
            let item = NSMenuItem(title: L.t(choice.vi, choice.en),
                                  action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.size
            item.state = Int(Preferences.bubbleSize) == choice.size ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: L.t("Kích thước bong bóng", "Bubble Size"),
                                  action: nil, keyEquivalent: "")
        sizeItem.image = Self.menuSymbol("circle.fill")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let display = Self.bubbleDisplayMenu(target: self, action: #selector(pickFollowDisplay(_:)),
                                             withSymbols: true)
        display.delegate = ChipMenuLift.shared
        let displayItem = NSMenuItem(title: L.t("Vị trí màn hình", "Display Placement"),
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

    /// 1×1 host for context menus — must outlive a single popUp call.
    private lazy var chipMenuAnchor: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
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
        guard bubbles.first != nil else { return }
        // Local + global monitors both see the same click — open once.
        let now = CACurrentMediaTime()
        if now - chipMenuShownAt < 0.35 { return }
        chipMenuShownAt = now
        // Cancel any pending auto-collapse so resignKey from the menu host
        // cannot fold the card while the user is picking.
        collapseWork?.cancel(); collapseWork = nil
        showChipMenu()
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
        clearChainState()
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
            // Like every other removal: the card, tether and hover focus must
            // not stay attached to a head that is gone.
            adjustIndicesAfterRemoval(bubbles.count - 1)
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
        #if DEBUG   // the log line is a no-op in release, the loop around it is not
        for (i, sc) in NSScreen.screens.enumerated() {
            PlumeTrace.log("  screen[\(i)] frame=\(PlumeTrace.r(sc.frame)) visible=\(PlumeTrace.r(sc.visibleFrame))")
        }
        #endif
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
        // link inside the card leaves the last-opened thread behind, and then
        // clicking that head folds the card away instead of returning to it.
        let live = ThreadURL.id(from: webView.url)
        if toggle, isExpanded, card.isVisible,
           (convo == nil && showingPicker) || (convo != nil && convo?.id == live) {
            collapse(); return
        }
        if let convo {
            // Promote the opened head to the newest contact slot.
            if let i = headIndex(for: convo.id), i != 1 {
                moveBubble(from: i, to: 1)
                lastOpenedIndex = 1
            }
            showThread(convo.url)
            // Reading it clears it; don't make the user wait for the next snapshot.
            bubbles.first { conversation(of: $0)?.id == convo.id }
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
            if let i = headIndex(for: ThreadURL.id(from: thread)) {
                lastOpenedIndex = i
                wake()
            }
            promoteOverlayStack()
            card.makeKey()
            return
        }
        if let i = headIndex(for: ThreadURL.id(from: thread)),
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

    /// Messenger settles asynchronously after a load, so the card's
    /// adjustments are retried on a short ladder rather than fired once.
    private static let fixupDelays: [TimeInterval] = [0, 0.15, 0.4, 0.9, 1.6, 2.6, 4.0]
    private var fixupWork: [DispatchWorkItem] = []

    private func scheduleCardFixups() {
        fixupWork.forEach { $0.cancel() }
        fixupWork.removeAll()
        for delay in Self.fixupDelays {
            let work = DispatchWorkItem { [weak self] in
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
    /// `settled` reports that the thread was already at its newest message.
    private func scrollToLatest(_ done: @escaping (_ settled: Bool) -> Void) {
        webView.evaluateJavaScript("window.__plumeScrollToLatest && window.__plumeScrollToLatest()") {
            result, _ in done((result as? String) == "settled")
        }
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

        let alreadyOpen = ThreadURL.id(from: webView.url) == ThreadURL.id(from: url)
        // Patch helpers onto the live page first — user scripts only run at
        // document start, so an already-open Messenger session would keep the
        // old "same URL ⇒ no-op" behaviour otherwise.
        // Click the inbox row *before* the card stylesheet hides it again, so
        // the fixups that re-apply it start only once the click is done:
        // CSS-hiding navigation first made `__plumeOpenThread` miss the link
        // and fall through to a full reload, which emptied the recents DOM
        // and wiped the bubble chain.
        webView.evaluateJavaScript(InjectedScript.threadHelpersJS) { [weak self] _, _ in
            self?.openThreadInPage(url, force: alreadyOpen)
        }
    }

    private func openThreadInPage(_ url: URL, force: Bool) {
        guard let live = webView.url, Plume.isInternal(live) else {
            webView.load(URLRequest(url: url))
            settleCard()
            return
        }
        webView.callAsyncJavaScript("return await window.__plumeOpenThreadRetry(href, force);",
                                    arguments: ["href": url.absoluteString, "force": force],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            // Never `load()` a thread URL on top of a live Messenger
            // session: a document reload tears down the inbox and the
            // next recents snapshot deletes every contact bubble. If the
            // row could not be clicked, at least point the card at the head
            // of the thread it still shows.
            if (try? result.get()) as? Bool == false {
                PlumeTrace.log("  openThread: no row to click")
                let shown = ThreadURL.id(from: self.webView.url)
                if let i = self.headIndex(for: shown) {
                    self.lastOpenedIndex = i
                    self.wake()
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

    /// Ladder of scroll-to-end attempts: Messenger mounts virtualised rows
    /// asynchronously after a resize / thread re-click. A new thread replaces
    /// the old ladder, so quick switching never stacks page-wide scans, and a
    /// thread already resting on its newest message ends the ladder early.
    private var scrollWork: [DispatchWorkItem] = []
    private var scrollLadder = 0

    private func scheduleScrollToLatest() {
        scrollWork.forEach { $0.cancel() }
        scrollWork.removeAll()
        scrollLadder += 1
        let ladder = scrollLadder
        var settled = 0
        for delay in [0.05, 0.2, 0.45, 0.9, 1.6, 2.8] {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isExpanded, !self.showingPicker else { return }
                self.scrollToLatest { [weak self] atEnd in
                    guard let self, self.scrollLadder == ladder else { return }
                    settled = atEnd ? settled + 1 : 0
                    if settled >= 2 { self.scrollWork.forEach { $0.cancel() } }
                }
            }
            scrollWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// The app chip opens our own list — Messenger's inbox URL immediately
    /// redirects into the most recent conversation, so its list can't be shown.
    private func showPicker() {
        showingPicker = true
        pushCardClip()
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
            self.lastOpenedIndex = self.headIndex(for: convo.id) ?? 0
            self.showThread(convo.url)
        }
        listView.onLoadMore = { [weak self] in self?.loadMorePicker() }
        listView.onDelete = { [weak self] convo in
            self?.deleteConversation?(convo) { [weak self] deleted in
                guard let self, deleted else { return }
                // Its head goes too; index 0 is the app chip and never does.
                if let i = self.headIndex(for: convo.id), i > 0 {
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
        let finish: () -> Void = { [weak self] in
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
        guard expandFirst else { finish(); return }
        webView.evaluateJavaScript("window.__plumeExpandConvList && window.__plumeExpandConvList()") { _, _ in
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

    /// Back to bubbles: the card folds down towards the head it came from.
    /// Ordering the card out and detaching the web view is what lets WebKit
    /// stop rendering it; the view itself stays alive so messages keep
    /// arriving and reopening is instant.
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
        stopTheaterPoll()
        if theaterMode { exitTheaterMode(restore: true) }
        isExpanded = false
        docked = false
        hoverFocus = nil
        pushCardClip()
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
        stopTheaterPoll()
        docked = false
        hoverFocus = nil
        tether.hide()
        teardownLoop()
        fixupWork.forEach { $0.cancel() }
        fixupWork.removeAll()
        scrollWork.forEach { $0.cancel() }
        scrollWork.removeAll()
        collapseWork?.cancel(); collapseWork = nil
        webView.removeFromSuperview()
        card.orderOut(nil)
        clearChainState()
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
        var size = Preferences.bubbleCardSize ?? Self.cardSize
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
        guard let saved = Preferences.bubbleCardSize else { return }
        let visible = hostScreen.visibleFrame
        let size = NSSize(width: min(max(saved.width, card.minSize.width), visible.width),
                          height: min(max(saved.height, card.minSize.height), visible.height))
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
        stopMousePoll()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    private func startMousePoll() {
        guard mousePoll == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        // Lets the system coalesce this wake-up with others; it runs for as
        // long as bubble mode is on.
        t.tolerance = 0.008
        RunLoop.main.add(t, forMode: .common)
        mousePoll = t
    }

    private func stopMousePoll() {
        mousePoll?.invalidate()
        mousePoll = nil
        foreignScreenTicks = 0
    }

    private func pollMouse() {
        guard !NSScreen.screens.isEmpty else { return }
        let p = NSEvent.mouseLocation
        if dragging {
            // Button released on another display never reaches the chip view.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                PlumeTrace.log("  drag mouseUp@\(PlumeTrace.p(p)) via poll")
                endDrag(velocity: Chain.flickVelocity(dragSamples))
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
        // No display to lay out on: rest until `screensChanged` wakes us.
        guard !bubbles.isEmpty, !NSScreen.screens.isEmpty else { park(); return }

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

        // Re-apply sticky focus weights only. Re-picking from geometry belongs
        // in `cursorMoved` / `pollMouse`; here packing springs would flip the
        // winner every frame and the zoom would stutter.
        applyHoverFromFocus()
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
            chip(panel)?.setDiameter(diameters[i])
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
                endDrag(velocity: Chain.flickVelocity(dragSamples))
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
    /// Following the cursor to another display is left to `pollMouse`: its
    /// debounce counts 30 Hz ticks, and feeding it every mouse event too
    /// shrank the ~160ms wait to a few milliseconds on a fast mouse.
    private func cursorMoved() {
        let before = hoverTargets
        recomputeHoverTargets()
        syncBubbleClickThrough()
        if before != hoverTargets { wake() }
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

    /// Slot-based Dock magnification. Vertical column uses Y; the docked card
    /// row uses X. The head that owns the open card stays enlarged even when
    /// the pointer is over a neighbour.
    private func recomputeHoverTargets() {
        let p = NSEvent.mouseLocation
        lastHoverMouse = p
        pickHoverFocus(at: p)
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
    private func pickHoverFocus(at p: NSPoint) {
        guard !bubbles.isEmpty, centres.count == bubbles.count else {
            hoverFocus = nil
            return
        }
        let horizontal = docked
        let probes: [NSPoint] = horizontal ? rowRestSlots() : restCentresForHover()
        guard !probes.isEmpty else { hoverFocus = nil; return }

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
            return
        }

        // Hysteresis: keep focus until another probe is clearly closer.
        if let focus = hoverFocus, focus < dist.count, dist[focus] <= fieldR + Chain.step * 0.25 {
            let margin = Chain.step * 0.28
            if nearest.offset != focus, nearest.element < dist[focus] - margin {
                hoverFocus = nearest.offset
            }
            return
        }
        hoverFocus = nearest.offset
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

    /// Release: the flick is loaded straight into the anchor spring, which lands
    /// on the nearest edge and keeps the whole chain — not just the grabbed
    /// bubble — on screen.
    private func endDrag(velocity: NSPoint) {
        guard dragging else { return }   // idempotent; a stray call is a no-op
        dragging = false
        bubbles.forEach { chip($0)?.cancelPress() }
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
        let found = best ?? NSScreen.screens.min {
            hypot($0.frame.midX - p.x, $0.frame.midY - p.y)
                < hypot($1.frame.midX - p.x, $1.frame.midY - p.y)
        } ?? NSScreen.main
        if let found { lastKnownScreen = found; return found }
        // While displays reconfigure, `NSScreen.screens` can be briefly empty
        // (a clamshell Mac losing its only monitor); `screens[0]` trapped here.
        // The display we were last on is the best answer until one returns.
        return lastKnownScreen ?? NSScreen()
    }

    private var lastKnownScreen: NSScreen? = NSScreen.main ?? NSScreen.screens.first

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
        Preferences.bubbleOrigin = c
    }

    private func savedHeadCentre() -> NSPoint {
        var c: NSPoint
        if let saved = Preferences.bubbleOrigin {
            c = saved
        } else {
            let v = (NSScreen.main ?? screen(nearest: .zero)).visibleFrame
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

// MARK: - Settings submenus shared with the Window menu

extension ChatBubbleController {
    /// "Maximum Bubbles". Built here for both the Window menu and the app
    /// chip's menu, which used to drift apart in choices and wording.
    static func bubbleLimitMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for n in Preferences.bubbleLimitChoices {
            let item = NSMenuItem(title: "\(n)", action: action, keyEquivalent: "")
            item.target = target
            item.tag = n
            item.state = Preferences.bubbleLimit == n ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Follow the active display (tag 1) or stay on the current one (tag 0).
    static func bubbleDisplayMenu(target: AnyObject, action: Selector,
                                  withSymbols: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let choices = [(1, "Theo màn hình đang hoạt động", "Follow Active Display", "arrow.triangle.2.circlepath"),
                       (0, "Giữ nguyên màn hình hiện tại", "Stay on Current Display", "pin")]
        for (tag, vi, en, symbol) in choices {
            let item = NSMenuItem(title: L.t(vi, en), action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            item.state = (tag == 1) == Preferences.bubbleFollowActiveDisplay ? .on : .off
            if withSymbols { item.image = menuSymbol(symbol) }
            menu.addItem(item)
        }
        return menu
    }
}
