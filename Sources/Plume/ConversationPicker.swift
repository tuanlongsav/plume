import AppKit

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
final class FlippedView: NSView {
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
