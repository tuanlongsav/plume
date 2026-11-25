import AppKit
import PlumeCore
import PlumeUI

/// Settings submenus shared by the Window menu and the app-chip context menu,
/// keeping their choices and wording from drifting apart.
public enum BubbleMenus {
    public static func limitMenu(target: AnyObject, action: Selector) -> NSMenu {
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
    public static func displayMenu(target: AnyObject, action: Selector,
                                   withSymbols: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let choices = [
            (1, "Theo màn hình đang hoạt động", "Follow Active Display", "arrow.triangle.2.circlepath"),
            (0, "Giữ nguyên màn hình hiện tại", "Stay on Current Display", "pin"),
        ]
        for (tag, vi, en, symbol) in choices {
            let item = NSMenuItem(title: L.t(vi, en), action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            item.state = (tag == 1) == Preferences.bubbleFollowActiveDisplay ? .on : .off
            if withSymbols { item.image = NSImage.plumeMenuSymbol(symbol) }
            menu.addItem(item)
        }
        return menu
    }
}

/// Presents the app chip's right-click menu lifted above `.screenSaver` bubbles.
final class BubbleChipMenuPresenter: NSObject {
    var onExitBubbleMode: (() -> Void)?
    var onPickLimit: ((Int) -> Void)?
    var onPickSize: ((CGFloat) -> Void)?
    var onPickFollowDisplay: ((Bool) -> Void)?

    /// 2×2 host for context menus — must outlive a single popUp call.
    private lazy var anchor: OverlayPanel = OverlayPanel.makeMenuAnchor()
    private var lastShownAt: CFTimeInterval = 0

    /// Debounced presentation for global + local right-click monitors, which
    /// both see the same click.
    func showFromMonitor(beforeShow: () -> Void) {
        let now = CACurrentMediaTime()
        guard now - lastShownAt >= 0.35 else { return }
        lastShownAt = now
        beforeShow()
        show()
    }

    func show() {
        let menu = NSMenu()
        // Bubbles sit at `.screenSaver`; AppKit's default menu window is only
        // `.popUpMenu` (~101) and opens *under* the chain — looks like right-
        // click does nothing. Elevate tracking menus to our overlay tier.
        menu.delegate = ChipMenuLift.shared

        let back = NSMenuItem(title: L.t("Về cửa sổ chính", "Back to Main Window"),
                              action: #selector(exitBubbleMode), keyEquivalent: "")
        back.target = self
        back.image = NSImage.plumeMenuSymbol("macwindow")
        menu.addItem(back)
        menu.addItem(.separator())

        let limits = BubbleMenus.limitMenu(target: self, action: #selector(pickLimit(_:)))
        limits.delegate = ChipMenuLift.shared
        let limitItem = NSMenuItem(title: L.t("Số bong bóng tối đa", "Maximum Bubbles"),
                                   action: nil, keyEquivalent: "")
        limitItem.image = NSImage.plumeMenuSymbol("circle.grid.2x2")
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
        sizeItem.image = NSImage.plumeMenuSymbol("circle.fill")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let display = BubbleMenus.displayMenu(target: self, action: #selector(pickFollowDisplay(_:)),
                                              withSymbols: true)
        display.delegate = ChipMenuLift.shared
        let displayItem = NSMenuItem(title: L.t("Vị trí màn hình", "Display Placement"),
                                     action: nil, keyEquivalent: "")
        displayItem.image = NSImage.plumeMenuSymbol("display")
        displayItem.submenu = display
        menu.addItem(displayItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L.t("Thoát Plume", "Quit Plume"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.image = NSImage.plumeMenuSymbol("power")
        menu.addItem(quit)

        // Anchor in a tiny panel at our overlay level so the menu is parented
        // into the same Space / tier as the bubbles (not the desktop Space).
        let mouse = NSEvent.mouseLocation
        PlumeOverlay.apply(to: anchor)
        anchor.setFrame(NSRect(x: mouse.x, y: mouse.y - 1, width: 2, height: 2), display: false)
        anchor.orderFrontRegardless()
        ChipMenuLift.elevateOpenMenus()
        menu.popUp(positioning: nil, at: NSPoint(x: 1, y: 1), in: anchor.contentView)
        anchor.orderOut(nil)
    }

    @objc private func exitBubbleMode() { onExitBubbleMode?() }
    @objc private func pickLimit(_ sender: NSMenuItem) { onPickLimit?(sender.tag) }
    @objc private func pickSize(_ sender: NSMenuItem) { onPickSize?(CGFloat(sender.tag)) }
    @objc private func pickFollowDisplay(_ sender: NSMenuItem) { onPickFollowDisplay?(sender.tag == 1) }
}
