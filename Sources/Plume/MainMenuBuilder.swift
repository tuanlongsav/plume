import AppKit
import PlumeBubble
import PlumeCore
import PlumeUpdater
import PlumeWeb

/// Builds Plume's main menu bar and menu-bar status menu, and validates every
/// menu item against live app/controller state.
enum MainMenuBuilder {
    static func buildMainMenu(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu(target: target))
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeViewMenu(target: target))
        mainMenu.addItem(makeConversationMenu(target: target))
        let windowItem = makeWindowMenu(target: target)
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowItem.submenu
        return mainMenu
    }

    /// Right-click menu of the menu bar icon. Built on each open, so its
    /// titles and checkmarks are current; `validate` fills them in.
    static func buildStatusMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L.t("Mở Plume", "Open Plume"),
                     action: #selector(AppDelegate.summon), keyEquivalent: "").target = target
        menu.addItem(withTitle: L.t("Bong bóng", "Chat Bubble"),
                     action: #selector(AppDelegate.toggleChatBubble), keyEquivalent: "").target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Phím tắt toàn cục \(Summon.hotKeyLabel)",
                                    "Global Shortcut \(Summon.hotKeyLabel)"),
                     action: #selector(AppDelegate.toggleGlobalHotKey), keyEquivalent: "").target = target
        menu.addItem(withTitle: L.t("Hiện biểu tượng trên thanh menu", "Show in Menu Bar"),
                     action: #selector(AppDelegate.toggleMenuBarIcon), keyEquivalent: "").target = target
        menu.addItem(withTitle: L.t("Ẩn số chưa đọc", "Hide Unread Count"),
                     action: #selector(AppDelegate.toggleHideUnreadCount), keyEquivalent: "").target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Thoát Plume", "Quit Plume"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    static func validate(_ item: NSMenuItem,
                         controller: WebViewController,
                         window: NSWindow,
                         hasHotKey: Bool,
                         canZoomPage: Bool,
                         summonAction: Summon.Action) -> Bool {
        switch item.action {
        // Mirror the toolbar: grey out when there's nowhere to go.
        case #selector(AppDelegate.goBack):    return controller.canGoBack
        case #selector(AppDelegate.goForward): return controller.canGoForward
        // Dark / Follow System are a tri-state on `forceDark`: true / false / nil.
        case #selector(AppDelegate.toggleDark):    item.state = Preferences.forceDark == true ? .on : .off
        case #selector(AppDelegate.followSystem):  item.state = Preferences.forceDark == nil ? .on : .off
        case #selector(AppDelegate.toggleCompact): item.state = controller.isCompact ? .on : .off
        case #selector(AppDelegate.toggleWebStyling): item.state = controller.isWebStyling ? .on : .off
        case #selector(AppDelegate.toggleBlockTrackers): item.state = controller.isBlockingTrackers ? .on : .off
        case #selector(AppDelegate.toggleAlwaysOnTop): item.state = Preferences.alwaysOnTop ? .on : .off
        case #selector(AppDelegate.setBubbleLimit(_:)):
            item.state = Preferences.bubbleLimit == item.tag ? .on : .off
        case #selector(AppDelegate.setBubbleFollowDisplay(_:)):
            let follow = Preferences.bubbleFollowActiveDisplay
            item.state = (item.tag == 1) == follow ? .on : .off
        case #selector(AppDelegate.toggleChatBubble):
            item.title = ChatBubbleController.isOpen
                ? L.t("Về cửa sổ chính", "Back to Main Window")
                : L.t("Chuyển sang bong bóng", "Switch to Chat Bubble")
        case #selector(AppDelegate.zoomInPage):     return canZoomPage && PageZoom.canZoomIn(controller.pageZoom)
        case #selector(AppDelegate.zoomOutPage):    return canZoomPage && PageZoom.canZoomOut(controller.pageZoom)
        case #selector(AppDelegate.actualSizePage): return canZoomPage && !PageZoom.isActual(controller.pageZoom)
        case #selector(AppDelegate.toggleMenuBarIcon): item.state = Preferences.menuBarIcon ? .on : .off
        case #selector(AppDelegate.toggleHideUnreadCount): item.state = Preferences.hideUnreadCount ? .on : .off
        // Ticked only while registered (`toggleGlobalHotKey`).
        case #selector(AppDelegate.toggleGlobalHotKey): item.state = hasHotKey ? .on : .off
        case #selector(AppDelegate.summon):
            if ChatBubbleController.isOpen {
                item.title = L.t("Mở / gập bong bóng", "Open / Fold Chat Bubble")
            } else {
                item.title = summonAction == .hide ? L.t("Ẩn Plume", "Hide Plume") : L.t("Mở Plume", "Open Plume")
            }
        case #selector(AppDelegate.toggleShortcuts): item.state = Preferences.shortcuts ? .on : .off
        case #selector(AppDelegate.toggleAutoUpdate): item.state = Preferences.autoUpdateCheck ? .on : .off
        case #selector(AppDelegate.jumpToConversation(_:)), #selector(AppDelegate.nextConversation),
             #selector(AppDelegate.prevConversation), #selector(AppDelegate.nextUnread),
             #selector(AppDelegate.findConversation):
            return Preferences.shortcuts
        // The card composes from its own list; a fallback page load here
        // would empty the list the chain is built from.
        case #selector(AppDelegate.newMessage):
            return Preferences.shortcuts && !ChatBubbleController.isOpen
        // The bubble card has its own delete, on the picker's rows.
        case #selector(AppDelegate.deleteConversation):
            return controller.canDeleteCurrentConversation && !ChatBubbleController.isOpen
        case #selector(AppDelegate.toggleChrome):
            item.title = (window.toolbar?.isVisible ?? true)
                ? L.t("Ẩn thanh công cụ", "Hide Toolbar")
                : L.t("Hiện thanh công cụ", "Show Toolbar")
        default: break
        }
        return true
    }

    // MARK: Submenu builders

    private static func makeAppMenu(target: AppDelegate) -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L.t("Giới thiệu Plume", "About Plume"),
                        action: #selector(AppDelegate.showAbout), keyEquivalent: "").target = target
        appMenu.addItem(withTitle: L.t("Kiểm tra cập nhật…", "Check for Updates…"),
                        action: #selector(Updater.checkNow(_:)), keyEquivalent: "").target = Updater.shared
        appMenu.addItem(withTitle: L.t("Tự động kiểm tra cập nhật", "Check for Updates Automatically"),
                        action: #selector(AppDelegate.toggleAutoUpdate), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("Hiện biểu tượng trên thanh menu", "Show in Menu Bar"),
                        action: #selector(AppDelegate.toggleMenuBarIcon), keyEquivalent: "").target = target
        appMenu.addItem(withTitle: L.t("Ẩn số chưa đọc", "Hide Unread Count"),
                        action: #selector(AppDelegate.toggleHideUnreadCount), keyEquivalent: "").target = target
        appMenu.addItem(withTitle: L.t("Phím tắt toàn cục \(Summon.hotKeyLabel)",
                                       "Global Shortcut \(Summon.hotKeyLabel)"),
                        action: #selector(AppDelegate.toggleGlobalHotKey), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("Ẩn Plume", "Hide Plume"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L.t("Ẩn các ứng dụng khác", "Hide Others"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L.t("Hiện tất cả", "Show All"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("Thoát Plume", "Quit Plume"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return appItem
    }

    private static func makeEditMenu() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L.t("Sửa", "Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L.t("Hoàn tác", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L.t("Làm lại", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L.t("Cắt", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L.t("Sao chép", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L.t("Dán", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L.t("Chọn tất cả", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return editItem
    }

    private static func makeViewMenu(target: AppDelegate) -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L.t("Xem", "View"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: L.t("Tải lại", "Reload"),
                         action: #selector(AppDelegate.reload), keyEquivalent: "r").target = target
        let back = viewMenu.addItem(withTitle: L.t("Lùi", "Back"),
                                    action: #selector(AppDelegate.goBack), keyEquivalent: "[")
        back.target = target
        let fwd = viewMenu.addItem(withTitle: L.t("Tiến", "Forward"),
                                   action: #selector(AppDelegate.goForward), keyEquivalent: "]")
        fwd.target = target
        let chats = viewMenu.addItem(withTitle: L.t("Về Đoạn chat", "Back to Chats"),
                                     action: #selector(AppDelegate.goToChats), keyEquivalent: "h")
        chats.keyEquivalentModifierMask = [.command, .shift]
        chats.target = target
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: L.t("Vào chế độ toàn màn hình", "Enter Full Screen"),
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // Page zoom, Safari's keys. ⌘0 is free: the conversation shortcuts are ⌘1–⌘9.
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L.t("Kích thước thật", "Actual Size"),
                         action: #selector(AppDelegate.actualSizePage), keyEquivalent: "0").target = target
        viewMenu.addItem(withTitle: L.t("Phóng to trang", "Zoom In"),
                         action: #selector(AppDelegate.zoomInPage), keyEquivalent: "+").target = target
        // ⌘+ is typed as ⌘= on most layouts; a hidden twin takes that key.
        let zoomInAlias = viewMenu.addItem(withTitle: L.t("Phóng to trang", "Zoom In"),
                                           action: #selector(AppDelegate.zoomInPage), keyEquivalent: "=")
        zoomInAlias.target = target
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: L.t("Thu nhỏ trang", "Zoom Out"),
                         action: #selector(AppDelegate.zoomOutPage), keyEquivalent: "-").target = target

        // Appearance / theming toggles (mirror the toolbar).
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L.t("Nền tối", "Dark Mode"),
                         action: #selector(AppDelegate.toggleDark), keyEquivalent: "d").target = target
        viewMenu.addItem(withTitle: L.t("Theo giao diện hệ thống", "Follow System Appearance"),
                         action: #selector(AppDelegate.followSystem), keyEquivalent: "").target = target
        let compact = viewMenu.addItem(withTitle: L.t("Hiển thị thu gọn", "Compact Density"),
                                       action: #selector(AppDelegate.toggleCompact), keyEquivalent: "d")
        compact.keyEquivalentModifierMask = [.command, .shift]
        compact.target = target
        viewMenu.addItem(withTitle: L.t("Tuỳ biến giao diện web", "Web Styling"),
                         action: #selector(AppDelegate.toggleWebStyling), keyEquivalent: "").target = target
        viewMenu.addItem(withTitle: L.t("Chặn trình theo dõi bên thứ ba", "Block Third-Party Trackers"),
                         action: #selector(AppDelegate.toggleBlockTrackers), keyEquivalent: "").target = target
        viewMenu.addItem(.separator())
        let hideToolbar = viewMenu.addItem(withTitle: L.t("Ẩn thanh công cụ", "Hide Toolbar"),
                                           action: #selector(AppDelegate.toggleChrome), keyEquivalent: "t")
        hideToolbar.keyEquivalentModifierMask = [.command, .option]   // macOS convention
        hideToolbar.target = target
        return viewItem
    }

    private static func makeConversationMenu(target: AppDelegate) -> NSMenuItem {
        let convItem = NSMenuItem()
        let convMenu = NSMenu(title: L.t("Đoạn chat", "Conversation"))
        convItem.submenu = convMenu
        for n in 1...9 {
            let it = convMenu.addItem(withTitle: L.t("Đoạn chat \(n)", "Conversation \(n)"),
                                      action: #selector(AppDelegate.jumpToConversation(_:)), keyEquivalent: "\(n)")
            it.keyEquivalentModifierMask = [.command]
            it.tag = n
            it.target = target
        }
        convMenu.addItem(.separator())
        let nextConv = convMenu.addItem(withTitle: L.t("Đoạn chat tiếp theo", "Select Next Conversation"),
                                        action: #selector(AppDelegate.nextConversation), keyEquivalent: "\t")
        nextConv.keyEquivalentModifierMask = [.control]
        nextConv.target = target
        let prevConv = convMenu.addItem(withTitle: L.t("Đoạn chat trước", "Select Previous Conversation"),
                                        action: #selector(AppDelegate.prevConversation), keyEquivalent: "\t")
        prevConv.keyEquivalentModifierMask = [.control, .shift]
        prevConv.target = target
        let unread = convMenu.addItem(withTitle: L.t("Đoạn chat chưa đọc tiếp theo", "Next Unread Conversation"),
                                      action: #selector(AppDelegate.nextUnread), keyEquivalent: "u")
        unread.keyEquivalentModifierMask = [.command, .shift]
        unread.target = target
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: L.t("Tin nhắn mới", "New Message"),
                         action: #selector(AppDelegate.newMessage), keyEquivalent: "n").target = target
        convMenu.addItem(withTitle: L.t("Tìm đoạn chat…", "Find Conversation…"),
                         action: #selector(AppDelegate.findConversation), keyEquivalent: "k").target = target
        convMenu.addItem(.separator())
        // ⇧⌘⌫, not ⌘⌫: a menu shortcut wins over the composer, where ⌘⌫ is
        // "delete to start of line".
        let deleteConv = convMenu.addItem(withTitle: L.t("Xoá đoạn chat…", "Delete Conversation…"),
                                          action: #selector(AppDelegate.deleteConversation), keyEquivalent: "\u{8}")
        deleteConv.keyEquivalentModifierMask = [.command, .shift]
        deleteConv.target = target
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: L.t("Bật phím tắt đoạn chat", "Enable Conversation Shortcuts"),
                         action: #selector(AppDelegate.toggleShortcuts), keyEquivalent: "").target = target
        return convItem
    }

    private static func makeWindowMenu(target: AppDelegate) -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L.t("Cửa sổ", "Window"))
        windowItem.submenu = windowMenu
        // Without it no window — PDF viewer, call popup, main — closed on ⌘W.
        windowMenu.addItem(withTitle: L.t("Đóng", "Close"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L.t("Thu nhỏ", "Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L.t("Thu phóng", "Zoom"),
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let bubbleItem = windowMenu.addItem(withTitle: L.t("Bong bóng", "Chat Bubble"),
                                            action: #selector(AppDelegate.toggleChatBubble), keyEquivalent: "b")
        bubbleItem.keyEquivalentModifierMask = [.command, .option]
        bubbleItem.target = target

        let limitItem = windowMenu.addItem(withTitle: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                           action: nil, keyEquivalent: "")
        limitItem.submenu = BubbleMenus.limitMenu(
            target: target, action: #selector(AppDelegate.setBubbleLimit(_:)))
        let displayItem = windowMenu.addItem(
            withTitle: L.t("Vị trí màn hình bong bóng", "Bubble Display Placement"),
            action: nil, keyEquivalent: "")
        displayItem.submenu = BubbleMenus.displayMenu(
            target: target, action: #selector(AppDelegate.setBubbleFollowDisplay(_:)))
        windowMenu.addItem(withTitle: L.t("Luôn ở trên cùng", "Always on Top"),
                           action: #selector(AppDelegate.toggleAlwaysOnTop), keyEquivalent: "").target = target
        return windowItem
    }
}
