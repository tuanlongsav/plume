import AppKit
import PlumeCore
import PlumeUI

/// The native unified-toolbar chrome: a vibrancy header (traffic lights kept
/// system-drawn) with Back / Forward / Reload on the leading edge and the
/// Dark / Compact toggles trailing. Hiding the toolbar gives the "zero-chrome"
/// variant (just traffic lights + centred title).
public final class ChromeToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    public let toolbar = NSToolbar(identifier: "PlumeToolbar")
    private weak var controller: WebViewController?
    private let onToggleBubble: () -> Void

    private var darkButton: NSButton?
    private var compactButton: NSButton?

    private enum ID {
        static let back = NSToolbarItem.Identifier("plume.back")
        static let forward = NSToolbarItem.Identifier("plume.forward")
        static let reload = NSToolbarItem.Identifier("plume.reload")
        static let dark = NSToolbarItem.Identifier("plume.dark")
        static let compact = NSToolbarItem.Identifier("plume.compact")
        static let bubble = NSToolbarItem.Identifier("plume.bubble")
    }

    public init(controller: WebViewController, onToggleBubble: @escaping () -> Void) {
        self.controller = controller
        self.onToggleBubble = onToggleBubble
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    // MARK: Delegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.back, ID.forward, ID.reload, .flexibleSpace, ID.bubble, ID.dark, ID.compact]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.back:
            return NSToolbarItem.plumeSymbolButton(
                id: id, symbol: "chevron.left", label: L.t("Lùi", "Back"),
                target: self, action: #selector(back), navigational: true)
        case ID.forward:
            return NSToolbarItem.plumeSymbolButton(
                id: id, symbol: "chevron.right", label: L.t("Tiến", "Forward"),
                target: self, action: #selector(forward), navigational: true)
        case ID.reload:
            return NSToolbarItem.plumeSymbolButton(
                id: id, symbol: "arrow.clockwise", label: L.t("Tải lại", "Reload"),
                target: self, action: #selector(reload), navigational: true)
        case ID.bubble:
            return NSToolbarItem.plumeSymbolButton(
                id: id, symbol: "bubble.left.and.bubble.right", label: L.t("Bong bóng", "Chat Bubble"),
                target: self, action: #selector(switchToBubble), navigational: true)
        case ID.dark:
            let (item, button) = toggleItem(id, symbol: "moon",
                                            label: L.t("Nền tối", "Dark"), action: #selector(toggleDark))
            darkButton = button
            return item
        case ID.compact:
            let (item, button) = toggleItem(id, symbol: "line.3.horizontal",
                                            label: L.t("Thu gọn", "Compact"), action: #selector(toggleCompact))
            compactButton = button
            return item
        default:
            return nil
        }
    }

    // MARK: Item builders

    private func toggleItem(_ id: NSToolbarItem.Identifier, symbol: String,
                            label: String, action: Selector) -> (NSToolbarItem, NSButton) {
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.target = self
        button.action = action
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        item.paletteLabel = label
        return (item, button)
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ID.back:    return controller?.canGoBack ?? false
        case ID.forward: return controller?.canGoForward ?? false
        default:         return true
        }
    }

    // MARK: State refresh (toggle tint)

    /// Re-tint the toggles to match live state. Wire `controller.onChromeUpdate`
    /// to this.
    public func refresh() {
        darkButton?.contentTintColor = (controller?.isDarkForced ?? false) ? Theme.accent : nil
        compactButton?.contentTintColor = (controller?.isCompact ?? false) ? Theme.accent : nil
    }

    // MARK: Actions

    @objc private func back() { controller?.goBack() }
    @objc private func forward() { controller?.goForward() }
    @objc private func reload() { controller?.reload() }
    @objc private func switchToBubble() { onToggleBubble() }
    @objc private func toggleDark() { controller?.toggleDark() }
    @objc private func toggleCompact() { controller?.toggleCompact() }
}
