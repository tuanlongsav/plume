import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var window: NSWindow!
    private var controller: WebViewController!

    private var chrome: ChromeToolbar!

    /// Bubble mode is restored once per launch, on the first load that
    /// actually succeeded — `onPageReady`, not `onChromeUpdate`.
    private var didRestoreMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore the saved appearance override before any window shows.
        WebViewController.applyAppearance()
        // Purge last session's throwaway attachment copies before any run.
        WebViewController.clearDownloadCache()

        controller = WebViewController()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Plume"
        window.contentViewController = controller
        window.minSize = NSSize(width: 420, height: 520)
        window.setFrameAutosaveName("PlumeMainWindow")   // remember size/position
        window.delegate = self   // for full-screen ⇄ always-on-top reconciliation

        // Native unified-toolbar chrome (vibrancy header + traffic lights).
        chrome = ChromeToolbar(controller: controller)
        window.toolbar = chrome.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.toolbar?.isVisible = Preferences.toolbarVisible   // zero-chrome if off
        controller.onChromeUpdate = { [weak chrome] in chrome?.refresh() }
        controller.onPageReady = { [weak self] in self?.restoreLastModeIfNeeded() }
        chrome.refresh()
        applyAlwaysOnTop()   // restore the floating-window preference

        // Guard against a corrupt or degenerate saved frame. A frame smaller
        // than minSize (a 1×1 frame has been observed) leaves the window
        // invisible; fall back to the default size, centered on screen.
        if window.frame.width < window.minSize.width ||
            window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        buildMenu()

        // Ask for notification permission, then load the page.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        controller.load()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // In bubble mode the main window is intentionally hidden — leave it that
        // way and just resurface the bubble.
        if ChatBubbleController.isOpen { return true }
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Bubble mode deliberately hides the main window and leaves only panels,
        // which AppKit does not count as windows here — returning true would
        // quit the app the instant we switch modes.
        return !ChatBubbleController.isOpen
    }

    // MARK: Notification handling

    // Show banners even when Plume is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // A click reopens the relevant thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["plumeId"] as? Int {
            // Bubble mode: the main window is hidden and its web view is on
            // loan to the card, so surfacing it shows an empty shell — and
            // pulls the user out of whatever fullscreen Space they were in.
            if let bubbles = ChatBubbleController.shared {
                bubbles.openFromNotification { [weak self] done in
                    self?.controller.activateNotification(id: id, completion: done)
                }
                completionHandler()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            controller.activateNotification(id: id)
        }
        completionHandler()
    }

    // MARK: Menu

    @objc private func reload() { controller.reload() }
    @objc private func goBack() { controller.goBack() }
    @objc private func goForward() { controller.goForward() }

    @objc private func toggleDark() { controller.toggleDark() }
    @objc private func followSystem() { controller.followSystemAppearance() }
    @objc private func toggleCompact() { controller.toggleCompact() }
    @objc private func toggleWebStyling() { controller.toggleWebStyling() }
    @objc private func toggleChrome() {
        let visible = !(window.toolbar?.isVisible ?? true)
        window.toolbar?.isVisible = visible
        Preferences.toolbarVisible = visible
    }

    @objc private func setBubbleLimit(_ sender: NSMenuItem) {
        defer { ChatBubbleController.shared?.applyBubbleLimit() }
        Preferences.bubbleLimit = sender.tag
    }

    @objc private func setBubbleFollowDisplay(_ sender: NSMenuItem) {
        Preferences.bubbleFollowActiveDisplay = sender.tag == 1
    }

    /// Bubble mode replaces the main window rather than sitting alongside it:
    /// the whole point is a compact, private surface, so leaving the full
    /// window on screen would defeat it.
    @objc func toggleChatBubble() {
        if ChatBubbleController.isOpen { exitBubbleMode(); return }
        enterBubbleMode(announce: true)
    }

    /// Restore the mode the app was last used in. Silent, and patient: on a
    /// cold launch Messenger's conversation list is not there yet, so this is
    /// worth a few quiet retries rather than an alert the user never asked for.
    private func restoreLastModeIfNeeded() {
        guard !didRestoreMode else { return }
        didRestoreMode = true
        guard Preferences.bubbleMode, !ChatBubbleController.isOpen else { return }
        enterBubbleMode(announce: false)
    }

    /// Restoring is patient, which means it can still be pending when the user
    /// makes their own decision. Every retry re-reads the preference so a
    /// deliberate "leave bubble mode" is never undone a second later.
    private var restoreStillWanted: Bool {
        Preferences.bubbleMode && !ChatBubbleController.isOpen
    }

    private func enterBubbleMode(announce: Bool, attempt: Int = 0) {
        controller.fetchConversations(limit: Preferences.bubbleLimit) { [weak self] convos in
            guard let self, !ChatBubbleController.isOpen else { return }
            // The user may have decided for themselves while this was in flight.
            if !announce, !Preferences.bubbleMode { return }
            // Never hide the main window with nothing to replace it — if the
            // snapshot came back empty (list still loading, or Messenger's DOM
            // moved), the app would simply look like it vanished.
            guard !convos.isEmpty else {
                if !announce, attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self, self.restoreStillWanted else { return }
                        self.enterBubbleMode(announce: false, attempt: attempt + 1)
                    }
                    return
                }
                guard announce else { return }   // a restore that fails just stays put
                let alert = NSAlert()
                alert.messageText = L.t("Chưa lấy được danh sách hội thoại",
                                        "Couldn't read your conversation list")
                alert.informativeText = L.t(
                    "Hãy đợi Messenger tải xong danh sách hội thoại rồi thử lại.",
                    "Wait for Messenger's conversation list to finish loading, then try again.")
                alert.beginSheetModal(for: self.window, completionHandler: nil)
                return
            }
            // Lend the live web view: Messenger is already up in it, so the
            // first bubble opens instantly instead of booting a second copy.
            guard let lent = self.controller.lendWebView() else { return }
            let bubbles = ChatBubbleController.show(
                conversations: convos,
                webView: lent,
                onExit: { [weak self] in self?.exitBubbleMode() })
            // The main web view stays alive behind the hidden window, so it is
            // still the source of truth for the picker's list.
            bubbles.fetchConversations = { [weak self] limit, done in
                self?.controller.fetchConversations(limit: limit, completion: done)
            }
            bubbles.deleteConversation = { [weak self] convo, done in
                self?.controller.confirmAndDeleteConversation(
                    url: convo.url, name: convo.name, completion: done)
            }
            self.window.orderOut(nil)
            Preferences.bubbleMode = true
        }
    }

    private func exitBubbleMode() {
        Preferences.bubbleMode = false
        ChatBubbleController.hide()
        // Unconditional and idempotent: a main window with no web view in it is
        // the one failure this whole arrangement must never produce.
        controller.reclaimWebView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAlwaysOnTop() {
        Preferences.alwaysOnTop.toggle()
        applyAlwaysOnTop()
    }
    private func applyAlwaysOnTop() {
        // A .floating level breaks the native full-screen transition, so only
        // float while not full-screen.
        let float = Preferences.alwaysOnTop && !window.styleMask.contains(.fullScreen)
        window.level = float ? .floating : .normal
    }

    // Drop the floating level for full screen, restore it on exit.
    func windowWillEnterFullScreen(_ notification: Notification) { window.level = .normal }
    func windowDidExitFullScreen(_ notification: Notification) { applyAlwaysOnTop() }

    // Conversation navigation (Caprine port)
    @objc private func nextConversation() { controller.nextConversation() }
    @objc private func prevConversation() { controller.previousConversation() }
    @objc private func nextUnread()       { controller.nextUnreadConversation() }
    @objc private func findConversation() { controller.findConversation() }
    @objc private func jumpToConversation(_ sender: NSMenuItem) { controller.jumpToConversation(sender.tag) }
    @objc private func deleteConversation() { controller.deleteCurrentConversation() }
    @objc private func toggleShortcuts()  { Preferences.shortcuts.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        // Mirror the toolbar: grey out when there's nowhere to go.
        case #selector(goBack):    return controller.canGoBack
        case #selector(goForward): return controller.canGoForward
        // Dark / Follow System are a tri-state on `forceDark`: true / false / nil.
        case #selector(toggleDark):    item.state = Preferences.forceDark == true ? .on : .off
        case #selector(followSystem):  item.state = Preferences.forceDark == nil ? .on : .off
        case #selector(toggleCompact): item.state = controller.isCompact ? .on : .off
        case #selector(toggleWebStyling): item.state = controller.isWebStyling ? .on : .off
        case #selector(toggleAlwaysOnTop): item.state = Preferences.alwaysOnTop ? .on : .off
        case #selector(setBubbleLimit(_:)):
            item.state = Preferences.bubbleLimit == item.tag ? .on : .off
        case #selector(setBubbleFollowDisplay(_:)):
            let follow = Preferences.bubbleFollowActiveDisplay
            item.state = (item.tag == 1) == follow ? .on : .off
        case #selector(toggleChatBubble):
            item.title = ChatBubbleController.isOpen
                ? L.t("Về cửa sổ chính", "Back to Main Window")
                : L.t("Chuyển sang bong bóng", "Switch to Chat Bubble")
        case #selector(toggleShortcuts): item.state = Preferences.shortcuts ? .on : .off
        case #selector(jumpToConversation(_:)), #selector(nextConversation),
             #selector(prevConversation), #selector(nextUnread),
             #selector(findConversation):
            return Preferences.shortcuts
        // The bubble card has its own delete, on the picker's rows.
        case #selector(deleteConversation):
            return controller.canDeleteCurrentConversation && !ChatBubbleController.isOpen
        case #selector(toggleChrome):
            item.title = (window.toolbar?.isVisible ?? true) ? "Hide Toolbar" : "Show Toolbar"
        default: break
        }
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Plume", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Plume", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Plume", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — gives us cut/copy/paste/select-all/spellcheck for free.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        let back = viewMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        back.target = self
        let fwd = viewMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        fwd.target = self
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // Appearance / theming toggles (mirror the toolbar).
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Dark Mode", action: #selector(toggleDark), keyEquivalent: "d").target = self
        viewMenu.addItem(withTitle: "Follow System Appearance", action: #selector(followSystem), keyEquivalent: "").target = self
        let compact = viewMenu.addItem(withTitle: "Compact Density", action: #selector(toggleCompact), keyEquivalent: "d")
        compact.keyEquivalentModifierMask = [.command, .shift]
        compact.target = self
        viewMenu.addItem(withTitle: "Web Styling", action: #selector(toggleWebStyling), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        let hideToolbar = viewMenu.addItem(withTitle: "Hide Toolbar", action: #selector(toggleChrome), keyEquivalent: "t")
        hideToolbar.keyEquivalentModifierMask = [.command, .option]   // macOS convention
        hideToolbar.target = self

        // Conversation menu (Caprine port)
        let convItem = NSMenuItem()
        mainMenu.addItem(convItem)
        let convMenu = NSMenu(title: "Conversation")
        convItem.submenu = convMenu
        for n in 1...9 {
            let it = convMenu.addItem(withTitle: "Conversation \(n)",
                action: #selector(jumpToConversation(_:)), keyEquivalent: "\(n)")
            it.keyEquivalentModifierMask = [.command]
            it.tag = n
            it.target = self
        }
        convMenu.addItem(.separator())
        let nextConv = convMenu.addItem(withTitle: "Select Next Conversation",
            action: #selector(nextConversation), keyEquivalent: "\t")
        nextConv.keyEquivalentModifierMask = [.control]
        nextConv.target = self
        let prevConv = convMenu.addItem(withTitle: "Select Previous Conversation",
            action: #selector(prevConversation), keyEquivalent: "\t")
        prevConv.keyEquivalentModifierMask = [.control, .shift]
        prevConv.target = self
        let unread = convMenu.addItem(withTitle: "Next Unread Conversation",
            action: #selector(nextUnread), keyEquivalent: "u")
        unread.keyEquivalentModifierMask = [.command, .shift]
        unread.target = self
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: "Find Conversation…",
            action: #selector(findConversation), keyEquivalent: "k").target = self
        convMenu.addItem(.separator())
        // ⇧⌘⌫, not ⌘⌫: a menu shortcut wins over the composer, where ⌘⌫ is
        // "delete to start of line".
        let deleteConv = convMenu.addItem(withTitle: "Delete Conversation…",
            action: #selector(deleteConversation), keyEquivalent: "\u{8}")
        deleteConv.keyEquivalentModifierMask = [.command, .shift]
        deleteConv.target = self
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: "Enable Conversation Shortcuts",
            action: #selector(toggleShortcuts), keyEquivalent: "").target = self

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let bubbleItem = windowMenu.addItem(withTitle: "Chat Bubble",
                                            action: #selector(toggleChatBubble), keyEquivalent: "b")
        bubbleItem.keyEquivalentModifierMask = [.command, .option]
        bubbleItem.target = self

        let limitItem = windowMenu.addItem(withTitle: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                           action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for n in [3, 5, 8] {
            let it = limitMenu.addItem(withTitle: "\(n)", action: #selector(setBubbleLimit(_:)),
                                       keyEquivalent: "")
            it.tag = n
            it.target = self
        }
        limitItem.submenu = limitMenu
        let displayItem = windowMenu.addItem(
            withTitle: L.t("Vị trí màn hình bong bóng", "Bubble Display Placement"),
            action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let followIt = displayMenu.addItem(
            withTitle: L.t("Theo màn hình đang hoạt động", "Follow active display"),
            action: #selector(setBubbleFollowDisplay(_:)), keyEquivalent: "")
        followIt.tag = 1
        followIt.target = self
        let stayIt = displayMenu.addItem(
            withTitle: L.t("Giữ nguyên màn hình hiện tại", "Stay on current display"),
            action: #selector(setBubbleFollowDisplay(_:)), keyEquivalent: "")
        stayIt.tag = 0
        stayIt.target = self
        displayItem.submenu = displayMenu
        windowMenu.addItem(withTitle: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "").target = self
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
