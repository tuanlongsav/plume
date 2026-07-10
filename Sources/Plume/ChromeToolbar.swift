import AppKit

/// The native unified-toolbar chrome: a vibrancy header (traffic lights kept
/// system-drawn) with Back / Forward / Reload on the leading edge and the
/// Dark / Compact toggles trailing. Hiding the toolbar gives the "zero-chrome"
/// variant (just traffic lights + centred title).
final class ChromeToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    let toolbar = NSToolbar(identifier: "PlumeToolbar")
    private weak var controller: WebViewController?

    private var darkButton: NSButton?
    private var compactButton: NSButton?

    private enum ID {
        static let back = NSToolbarItem.Identifier("plume.back")
        static let forward = NSToolbarItem.Identifier("plume.forward")
        static let reload = NSToolbarItem.Identifier("plume.reload")
        static let dark = NSToolbarItem.Identifier("plume.dark")
        static let compact = NSToolbarItem.Identifier("plume.compact")
    }

    init(controller: WebViewController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    // MARK: Delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.back, ID.forward, ID.reload, .flexibleSpace, ID.dark, ID.compact]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.back:
            return navItem(id, symbol: "chevron.left",
                           label: L.t("Lùi", "Back"), action: #selector(back))
        case ID.forward:
            return navItem(id, symbol: "chevron.right",
                           label: L.t("Tiến", "Forward"), action: #selector(forward))
        case ID.reload:
            return navItem(id, symbol: "arrow.clockwise",
                           label: L.t("Tải lại", "Reload"), action: #selector(reload))
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

    private func navItem(_ id: NSToolbarItem.Identifier, symbol: String,
                         label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.isNavigational = true
        item.target = self
        item.action = action
        return item
    }

    private func toggleItem(_ id: NSToolbarItem.Identifier, symbol: String,
                            label: String, action: Selector) -> (NSToolbarItem, NSButton) {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        item.paletteLabel = label
        return (item, button)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ID.back:    return controller?.canGoBack ?? false
        case ID.forward: return controller?.canGoForward ?? false
        default:         return true
        }
    }

    // MARK: State refresh (toggle tint)

    /// Re-tint the toggles to match live state. Wire `controller.onChromeUpdate`
    /// to this.
    func refresh() {
        darkButton?.contentTintColor = (controller?.isDark ?? false) ? Theme.accent : nil
        compactButton?.contentTintColor = (controller?.isCompact ?? false) ? Theme.accent : nil
    }

    // MARK: Actions

    @objc private func back() { controller?.goBack() }
    @objc private func forward() { controller?.goForward() }
    @objc private func reload() { controller?.reload() }
    @objc private func toggleDark() { controller?.toggleDark() }
    @objc private func toggleCompact() { controller?.toggleCompact() }
}
