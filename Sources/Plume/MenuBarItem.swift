import AppKit

/// Plume's icon in the menu bar, with the unread count beside it.
///
/// A left click does what the global shortcut does (`AppDelegate.summon`);
/// a right or ⌃-click opens a small menu. The count follows the Dock badge
/// through `.plumeUnreadChanged`, so there is nothing to poll.
final class MenuBarItem: NSObject {
    private let item: NSStatusItem
    private let onClick: () -> Void
    private let makeMenu: () -> NSMenu
    private var shownTitle = ""

    init(unread: Int, onClick: @escaping () -> Void, makeMenu: @escaping () -> NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onClick = onClick
        self.makeMenu = makeMenu
        super.init()
        if let button = item.button {
            button.image = FeatherView.menuBarImage()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Plume")
        }
        setUnread(unread)
        NotificationCenter.default.addObserver(self, selector: #selector(unreadChanged(_:)),
                                               name: .plumeUnreadChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func unreadChanged(_ note: Notification) {
        setUnread(note.userInfo?["count"] as? Int ?? 0)
    }

    /// The notification fires on every title change; rewriting an unchanged
    /// title still re-lays out the menu bar, so only write a new one.
    private func setUnread(_ count: Int) {
        let title = Summon.statusTitle(unread: count)
        guard title != shownTitle, let button = item.button else { return }
        shownTitle = title
        button.title = title
        button.setAccessibilityValue(title.isEmpty
            ? nil
            : L.t("\(title) đoạn chat chưa đọc", "\(title) unread chats"))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else { onClick(); return }
        let menu = makeMenu()
        // In bubble mode the chat heads float at .screenSaver level and would
        // cover a menu opened near them; lift it like the chip menus.
        if ChatBubbleController.isOpen { menu.delegate = ChipMenuLift.shared }
        // Just below the icon, whichever way the button's coordinates run.
        let below = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
    }
}
