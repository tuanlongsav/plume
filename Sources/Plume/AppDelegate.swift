import AppKit
import PlumeBubble
import PlumeCore
import PlumeUI
import PlumeUpdater
import PlumeWeb
import UserNotifications
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var window: NSWindow!
    private var controller: WebViewController!
    private var chrome: ChromeToolbar!
    private var bubbleMode: BubbleModeCoordinator!

    /// Present only while the matching preference is on.
    private var menuBarItem: MenuBarItem?
    private var hotKey: GlobalHotKey?

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

        bubbleMode = BubbleModeCoordinator(window: window, controller: controller)

        // Native unified-toolbar chrome (vibrancy header + traffic lights).
        chrome = ChromeToolbar(controller: controller) { [weak self] in
            self?.bubbleMode.toggle()
        }
        window.toolbar = chrome.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.toolbar?.isVisible = Preferences.toolbarVisible   // zero-chrome if off
        controller.onChromeUpdate = { [weak chrome] in chrome?.refresh() }
        controller.onPageReady = { [weak self] in self?.bubbleMode.restoreLastModeIfNeeded() }
        chrome.refresh()
        applyAlwaysOnTop()   // restore the floating-window preference

        // Guard against a corrupt or degenerate saved frame.
        if window.frame.width < window.minSize.width ||
            window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        NSApp.mainMenu = MainMenuBuilder.buildMainMenu(target: self)
        applyMenuBarIcon()
        applyGlobalHotKey(reportFailure: false)

        // Ask for notification permission, then load the page.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        // The first load waits for the tracker blocker, briefly: a store
        // that never answers must not leave the splash up for good.
        var started = false
        let start = { [weak self] in
            guard !started else { return }
            started = true
            self?.controller.load()
        }
        controller.prepareTrackerBlocking(then: start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: start)
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
        // which AppKit does not count as windows here. With the menu bar icon on,
        // closing the window leaves Plume running there, notifications and all.
        return !ChatBubbleController.isOpen && !Preferences.menuBarIcon
    }

    // MARK: Menu bar icon and global shortcut

    /// Left click on the menu bar icon, or the global shortcut: bring the
    /// chats up, or put them away when they are already in front (`Summon`).
    @objc func summon() {
        if let bubbles = ChatBubbleController.shared {
            bubbles.toggleCardFromShortcut()
            return
        }
        switch summonAction {
        case .hide:
            NSApp.hide(nil)
        case .show:
            if NSApp.isHidden { NSApp.unhide(nil) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.plumeActivate(fromShortcut: true)
        }
    }

    /// A key window on another Space (or in its own full-screen Space) is not
    /// in front of the user: the shortcut must bring it here, not hide Plume.
    private var summonAction: Summon.Action {
        Summon.action(appActive: NSApp.isActive, appHidden: NSApp.isHidden,
                      mainWindowVisible: window.isVisible && window.isOnActiveSpace,
                      mainWindowKey: window.isKeyWindow)
    }

    @objc func toggleHideUnreadCount() {
        Preferences.hideUnreadCount.toggle()
        controller.republishUnread()
    }

    @objc func toggleMenuBarIcon() {
        Preferences.menuBarIcon.toggle()
        applyMenuBarIcon()
    }

    /// Goes by whether the shortcut works, not by the preference: a launch
    /// that could not register it leaves the preference on, and the next
    /// click must try again rather than turn it off.
    @objc func toggleGlobalHotKey() {
        Preferences.globalHotKey = hotKey == nil
        applyGlobalHotKey(reportFailure: true)
    }

    private func applyMenuBarIcon() {
        guard Preferences.menuBarIcon else { menuBarItem = nil; return }
        guard menuBarItem == nil else { return }
        menuBarItem = MenuBarItem(
            unread: controller.badgeCount,
            onClick: { [weak self] in self?.summon() },
            makeMenu: { [weak self] in
                guard let self else { return NSMenu() }
                return MainMenuBuilder.buildStatusMenu(target: self)
            }
        )
    }

    /// The system refuses a combination another app has registered. At launch
    /// that is silent (the preference stays on, for when the other app quits);
    /// when the user has just turned it on, say so and turn it back off.
    private func applyGlobalHotKey(reportFailure: Bool) {
        hotKey = nil   // unregister first, or re-registering the same key fails
        guard Preferences.globalHotKey else { return }
        hotKey = GlobalHotKey(keyCode: Summon.hotKeyCode,
                              modifiers: GlobalHotKey.controlOptionCommand) { [weak self] in
            self?.summon()
        }
        guard hotKey == nil, reportFailure else { return }
        Preferences.globalHotKey = false
        AlertPresenter.presentModal(
            title: L.t("Không dùng được phím tắt \(Summon.hotKeyLabel)",
                       "Couldn't use the \(Summon.hotKeyLabel) shortcut"),
            detail: L.t("Một ứng dụng khác đang dùng tổ hợp phím này.",
                        "Another app is already using this key combination.")
        )
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

    // MARK: Menu actions & validation

    @objc func reload() { controller.reload() }
    @objc func goBack() { controller.goBack() }
    @objc func goForward() { controller.goForward() }
    @objc func goToChats() { controller.goToChats() }

    /// The standard panel, plus the engine the page runs on: WKWebView uses
    /// the WebKit the OS shipped, not the installed Safari's, so a report from
    /// an older Mac is only useful with this line in it.
    @objc func showAbout() {
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

    @objc func toggleDark() { controller.toggleDark() }
    @objc func followSystem() { controller.followSystemAppearance() }
    @objc func toggleCompact() { controller.toggleCompact() }
    @objc func toggleWebStyling() { controller.toggleWebStyling() }
    @objc func toggleBlockTrackers() { controller.toggleBlockTrackers() }

    @objc func toggleChrome() {
        let visible = !(window.toolbar?.isVisible ?? true)
        window.toolbar?.isVisible = visible
        Preferences.toolbarVisible = visible
    }

    @objc func setBubbleLimit(_ sender: NSMenuItem) {
        defer { ChatBubbleController.shared?.applyBubbleLimit() }
        Preferences.bubbleLimit = sender.tag
    }

    @objc func setBubbleFollowDisplay(_ sender: NSMenuItem) {
        Preferences.bubbleFollowActiveDisplay = sender.tag == 1
    }

    @objc func toggleChatBubble() { bubbleMode.toggle() }

    @objc func toggleAlwaysOnTop() {
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
    @objc func nextConversation() { controller.nextConversation() }
    @objc func prevConversation() { controller.previousConversation() }
    @objc func nextUnread()       { controller.nextUnreadConversation() }
    @objc func findConversation() { controller.findConversation() }
    @objc func newMessage()       { controller.newMessage() }
    @objc func jumpToConversation(_ sender: NSMenuItem) { controller.jumpToConversation(sender.tag) }
    @objc func deleteConversation() { controller.deleteCurrentConversation() }
    @objc func zoomInPage()   { controller.setPageZoom(PageZoom.zoomedIn(from: controller.pageZoom)) }
    @objc func zoomOutPage()  { controller.setPageZoom(PageZoom.zoomedOut(from: controller.pageZoom)) }
    @objc func actualSizePage() { controller.setPageZoom(PageZoom.actual) }

    /// Zoom acts on the main window's page only. A PDF or call window that
    /// is key must not see ⌘+ silently rescale the window behind it, and the
    /// bubble card keeps zoom 1 (`WebViewController.lendWebView`).
    private var canZoomPage: Bool {
        !ChatBubbleController.isOpen && NSApp.keyWindow === window
    }

    @objc func toggleShortcuts()  { Preferences.shortcuts.toggle() }
    @objc func toggleAutoUpdate() { Preferences.autoUpdateCheck.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MainMenuBuilder.validate(
            item,
            controller: controller,
            window: window,
            hasHotKey: hotKey != nil,
            canZoomPage: canZoomPage,
            summonAction: summonAction
        )
    }
}
