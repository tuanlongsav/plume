import AppKit
import PlumeCore
import QuartzCore

public extension NSApplication {
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

    /// The menu bar icon, the global shortcut or a bubble panel: the user
    /// asked for Plume from inside another app. Cooperative `activate()` may
    /// decline while that app stays frontmost, and then the window would come
    /// up behind it; insist once if it did.
    func plumeActivate(fromShortcut: Bool) {
        plumeActivate()
        guard fromShortcut else { return }
        DispatchQueue.main.async { [self] in
            if !isActive { activate(ignoringOtherApps: true) }
        }
    }
}

public extension NSView {
    /// Four-edge constraints pinning `self` inside `container` with a uniform
    /// inset on every side.
    func pinEdges(to container: NSView, inset: CGFloat = 0) -> [NSLayoutConstraint] {
        [
            topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ]
    }
}

public extension CATransaction {
    /// Run `body` with Core Animation implicit actions disabled.
    static func withoutAnimation(_ body: () -> Void) {
        begin()
        setDisableActions(true)
        body()
        commit()
    }
}

public extension CATransform3D {
    /// Scale (and optionally shift) around `center` for layer-backed NSViews
    /// whose `anchorPoint` stays at `(0, 0)`.
    static func plumeCentered(center c: CGPoint,
                              scale s: CGFloat,
                              translation offset: CGPoint = .zero) -> CATransform3D {
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        if offset != .zero {
            t = CATransform3DTranslate(t, offset.x, offset.y, 0)
        }
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        return t
    }
}

public extension NSImage {
    /// Template SF Symbol sized for context menus.
    static func plumeMenuSymbol(_ name: String, pointSize: CGFloat = 14) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let sized = image.withSymbolConfiguration(config) ?? image
        sized.isTemplate = true
        return sized
    }
}

public extension NSMenuItem {
    /// "Delete Chat…" with a trash icon: the row menus of Messenger's sidebar
    /// and of the bubble picker.
    static func deleteChat(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L.t("Xoá đoạn chat…", "Delete Chat…"),
                              action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return item
    }
}

public extension NSToolbarItem {
    /// Standard bordered SF-Symbol button item shared across native toolbars.
    static func plumeSymbolButton(id: NSToolbarItem.Identifier,
                                  symbol: String,
                                  label: String,
                                  target: AnyObject,
                                  action: Selector,
                                  navigational: Bool = false) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.isBordered = true
        if navigational { item.isNavigational = true }
        item.target = target
        item.action = action
        return item
    }
}
