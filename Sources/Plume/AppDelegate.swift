import AppKit
import WebKit
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
        // We hold the window strongly; AppKit must not release it on close too.
        window.isReleasedWhenClosed = false
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
        NSApp.plumeActivate()
        Updater.shared.scheduleLaunchCheck()
    }

    /// A date comparison until a day has passed since the last update check,
    /// so it costs nothing on every activation.
    func applicationDidBecomeActive(_ notification: Notification) {
        Updater.shared.checkIfDue()
    }

    /// Opts into secure coding for restored window state; without it macOS 14
    /// logs a warning at every launch.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
            NSApp.plumeActivate()
            window.makeKeyAndOrderFront(nil)
            controller.activateNotification(id: id)
        }
        completionHandler()
    }

    // MARK: Menu

    @objc private func reload() { controller.reload() }
    @objc private func goBack() { controller.goBack() }
    @objc private func goForward() { controller.goForward() }
    @objc private func goToChats() { controller.goToChats() }

    /// The standard panel, plus the engine the page runs on: WKWebView uses
    /// the WebKit the OS shipped, not the installed Safari's, so a report from
    /// an older Mac is only useful with this line in it.
    @objc private func showAbout() {
        let webKit = Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let line = "WebKit \(webKit) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let credits = NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.plumeActivate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

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

    /// `wentToChats`: this attempt sequence loaded the chat list itself, so it
    /// must wait for it even when the user asked, instead of failing at once.
    private func enterBubbleMode(announce: Bool, attempt: Int = 0, wentToChats: Bool = false) {
        var wentToChats = wentToChats
        if controller.isOnLoginPage {
            guard announce else { return }
            showBubbleModeAlert(L.t("Hãy đăng nhập Facebook trước",
                                    "Log in to Facebook first"),
                                L.t("Messenger nằm trong Facebook sau khi bạn đăng nhập. Đăng nhập xong rồi thử lại.",
                                    "Messenger is inside Facebook once you are logged in. Log in, then try again."))
            return
        }
        // On facebook.com the window can be on the feed or a profile, which
        // have no chat list to read. Go to the list, then wait for it below.
        if attempt == 0, !ThreadURL.isMessagesSurface(controller.webView.url) {
            controller.goToChats()
            wentToChats = true
        }
        controller.fetchConversations(limit: Preferences.bubbleLimit) { [weak self] convos in
            guard let self, !ChatBubbleController.isOpen else { return }
            // The user may have decided for themselves while this was in flight.
            if !announce, !Preferences.bubbleMode { return }
            // Never hide the main window with nothing to replace it — if the
            // snapshot came back empty (list still loading, or Messenger's DOM
            // moved), the app would simply look like it vanished.
            guard !convos.isEmpty else {
                if !announce || wentToChats, attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { return }
                        if announce {
                            // The user may have opened bubbles by other means meanwhile.
                            guard !ChatBubbleController.isOpen else { return }
                        } else {
                            guard self.restoreStillWanted else { return }
                        }
                        self.enterBubbleMode(announce: announce, attempt: attempt + 1,
                                             wentToChats: wentToChats)
                    }
                    return
                }
                guard announce else { return }   // a restore that fails just stays put
                self.showBubbleModeAlert(
                    L.t("Chưa lấy được danh sách hội thoại", "Couldn't read your conversation list"),
                    L.t("Hãy đợi Messenger tải xong danh sách hội thoại rồi thử lại.",
                        "Wait for Messenger's conversation list to finish loading, then try again."))
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
            self.controller.republishUnread()
            self.window.orderOut(nil)
            Preferences.bubbleMode = true
        }
    }

    private func showBubbleModeAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func exitBubbleMode() {
        Preferences.bubbleMode = false
        ChatBubbleController.hide()
        // Unconditional and idempotent: a main window with no web view in it is
        // the one failure this whole arrangement must never produce.
        controller.reclaimWebView()
        window.makeKeyAndOrderFront(nil)
        NSApp.plumeActivate()
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
    @objc private func zoomInPage()   { controller.setPageZoom(PageZoom.zoomedIn(from: controller.pageZoom)) }
    @objc private func zoomOutPage()  { controller.setPageZoom(PageZoom.zoomedOut(from: controller.pageZoom)) }
    @objc private func actualSizePage() { controller.setPageZoom(PageZoom.actual) }

    /// Zoom acts on the main window's page only. A PDF or call window that
    /// is key must not see ⌘+ silently rescale the window behind it, and the
    /// bubble card keeps zoom 1 (`WebViewController.lendWebView`).
    private var canZoomPage: Bool {
        !ChatBubbleController.isOpen && NSApp.keyWindow === window
    }

    @objc private func toggleShortcuts()  { Preferences.shortcuts.toggle() }
    @objc private func toggleAutoUpdate() { Preferences.autoUpdateCheck.toggle() }

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
        case #selector(zoomInPage):     return canZoomPage && PageZoom.canZoomIn(controller.pageZoom)
        case #selector(zoomOutPage):    return canZoomPage && PageZoom.canZoomOut(controller.pageZoom)
        case #selector(actualSizePage): return canZoomPage && !PageZoom.isActual(controller.pageZoom)
        case #selector(toggleShortcuts): item.state = Preferences.shortcuts ? .on : .off
        case #selector(toggleAutoUpdate): item.state = Preferences.autoUpdateCheck ? .on : .off
        case #selector(jumpToConversation(_:)), #selector(nextConversation),
             #selector(prevConversation), #selector(nextUnread),
             #selector(findConversation):
            return Preferences.shortcuts
        // The bubble card has its own delete, on the picker's rows.
        case #selector(deleteConversation):
            return controller.canDeleteCurrentConversation && !ChatBubbleController.isOpen
        case #selector(toggleChrome):
            item.title = (window.toolbar?.isVisible ?? true)
                ? L.t("Ẩn thanh công cụ", "Hide Toolbar")
                : L.t("Hiện thanh công cụ", "Show Toolbar")
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
        appMenu.addItem(withTitle: L.t("Giới thiệu Plume", "About Plume"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L.t("Kiểm tra cập nhật…", "Check for Updates…"), action: #selector(Updater.checkNow(_:)), keyEquivalent: "").target = Updater.shared
        appMenu.addItem(withTitle: L.t("Tự động kiểm tra cập nhật", "Check for Updates Automatically"), action: #selector(toggleAutoUpdate), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("Ẩn Plume", "Hide Plume"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L.t("Ẩn các ứng dụng khác", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L.t("Hiện tất cả", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("Thoát Plume", "Quit Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — gives us cut/copy/paste/select-all/spellcheck for free.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
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

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L.t("Xem", "View"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: L.t("Tải lại", "Reload"), action: #selector(reload), keyEquivalent: "r").target = self
        let back = viewMenu.addItem(withTitle: L.t("Lùi", "Back"), action: #selector(goBack), keyEquivalent: "[")
        back.target = self
        let fwd = viewMenu.addItem(withTitle: L.t("Tiến", "Forward"), action: #selector(goForward), keyEquivalent: "]")
        fwd.target = self
        let chats = viewMenu.addItem(withTitle: L.t("Về Đoạn chat", "Back to Chats"), action: #selector(goToChats), keyEquivalent: "h")
        chats.keyEquivalentModifierMask = [.command, .shift]
        chats.target = self
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: L.t("Vào chế độ toàn màn hình", "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // Page zoom, Safari's keys. ⌘0 is free: the conversation shortcuts
        // are ⌘1–⌘9.
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L.t("Kích thước thật", "Actual Size"), action: #selector(actualSizePage), keyEquivalent: "0").target = self
        viewMenu.addItem(withTitle: L.t("Phóng to trang", "Zoom In"), action: #selector(zoomInPage), keyEquivalent: "+").target = self
        // ⌘+ is typed as ⌘= on most layouts; a hidden twin takes that key.
        let zoomInAlias = viewMenu.addItem(withTitle: L.t("Phóng to trang", "Zoom In"), action: #selector(zoomInPage), keyEquivalent: "=")
        zoomInAlias.target = self
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: L.t("Thu nhỏ trang", "Zoom Out"), action: #selector(zoomOutPage), keyEquivalent: "-").target = self

        // Appearance / theming toggles (mirror the toolbar).
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L.t("Nền tối", "Dark Mode"), action: #selector(toggleDark), keyEquivalent: "d").target = self
        viewMenu.addItem(withTitle: L.t("Theo giao diện hệ thống", "Follow System Appearance"), action: #selector(followSystem), keyEquivalent: "").target = self
        let compact = viewMenu.addItem(withTitle: L.t("Hiển thị thu gọn", "Compact Density"), action: #selector(toggleCompact), keyEquivalent: "d")
        compact.keyEquivalentModifierMask = [.command, .shift]
        compact.target = self
        viewMenu.addItem(withTitle: L.t("Tuỳ biến giao diện web", "Web Styling"), action: #selector(toggleWebStyling), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        let hideToolbar = viewMenu.addItem(withTitle: L.t("Ẩn thanh công cụ", "Hide Toolbar"), action: #selector(toggleChrome), keyEquivalent: "t")
        hideToolbar.keyEquivalentModifierMask = [.command, .option]   // macOS convention
        hideToolbar.target = self

        // Conversation menu (Caprine port)
        let convItem = NSMenuItem()
        mainMenu.addItem(convItem)
        let convMenu = NSMenu(title: L.t("Đoạn chat", "Conversation"))
        convItem.submenu = convMenu
        for n in 1...9 {
            let it = convMenu.addItem(withTitle: L.t("Đoạn chat \(n)", "Conversation \(n)"),
                action: #selector(jumpToConversation(_:)), keyEquivalent: "\(n)")
            it.keyEquivalentModifierMask = [.command]
            it.tag = n
            it.target = self
        }
        convMenu.addItem(.separator())
        let nextConv = convMenu.addItem(withTitle: L.t("Đoạn chat tiếp theo", "Select Next Conversation"),
            action: #selector(nextConversation), keyEquivalent: "\t")
        nextConv.keyEquivalentModifierMask = [.control]
        nextConv.target = self
        let prevConv = convMenu.addItem(withTitle: L.t("Đoạn chat trước", "Select Previous Conversation"),
            action: #selector(prevConversation), keyEquivalent: "\t")
        prevConv.keyEquivalentModifierMask = [.control, .shift]
        prevConv.target = self
        let unread = convMenu.addItem(withTitle: L.t("Đoạn chat chưa đọc tiếp theo", "Next Unread Conversation"),
            action: #selector(nextUnread), keyEquivalent: "u")
        unread.keyEquivalentModifierMask = [.command, .shift]
        unread.target = self
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: L.t("Tìm đoạn chat…", "Find Conversation…"),
            action: #selector(findConversation), keyEquivalent: "k").target = self
        convMenu.addItem(.separator())
        // ⇧⌘⌫, not ⌘⌫: a menu shortcut wins over the composer, where ⌘⌫ is
        // "delete to start of line".
        let deleteConv = convMenu.addItem(withTitle: L.t("Xoá đoạn chat…", "Delete Conversation…"),
            action: #selector(deleteConversation), keyEquivalent: "\u{8}")
        deleteConv.keyEquivalentModifierMask = [.command, .shift]
        deleteConv.target = self
        convMenu.addItem(.separator())
        convMenu.addItem(withTitle: L.t("Bật phím tắt đoạn chat", "Enable Conversation Shortcuts"),
            action: #selector(toggleShortcuts), keyEquivalent: "").target = self

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L.t("Cửa sổ", "Window"))
        windowItem.submenu = windowMenu
        // Without it no window — PDF viewer, call popup, main — closed on ⌘W.
        windowMenu.addItem(withTitle: L.t("Đóng", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L.t("Thu nhỏ", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L.t("Thu phóng", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let bubbleItem = windowMenu.addItem(withTitle: L.t("Bong bóng", "Chat Bubble"),
                                            action: #selector(toggleChatBubble), keyEquivalent: "b")
        bubbleItem.keyEquivalentModifierMask = [.command, .option]
        bubbleItem.target = self

        let limitItem = windowMenu.addItem(withTitle: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                           action: nil, keyEquivalent: "")
        limitItem.submenu = ChatBubbleController.bubbleLimitMenu(
            target: self, action: #selector(setBubbleLimit(_:)))
        let displayItem = windowMenu.addItem(
            withTitle: L.t("Vị trí màn hình bong bóng", "Bubble Display Placement"),
            action: nil, keyEquivalent: "")
        displayItem.submenu = ChatBubbleController.bubbleDisplayMenu(
            target: self, action: #selector(setBubbleFollowDisplay(_:)))
        windowMenu.addItem(withTitle: L.t("Luôn ở trên cùng", "Always on Top"), action: #selector(toggleAlwaysOnTop), keyEquivalent: "").target = self
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

extension NSApplication {
    /// `activate()` is macOS 14+ and cooperative: it yields when another app
    /// is frontmost and the user did not ask for Plume. macOS 13 has only
    /// `activate(ignoringOtherApps:)`, where `true` always takes focus, so
    /// work the user did not start (the daily update check) passes false.
    func plumeActivate(userInitiated: Bool = true) {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: userInitiated)
        }
    }
}
