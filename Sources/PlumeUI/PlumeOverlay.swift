import AppKit

/// Abstraction implemented by the active overlay presenter (bubble mode) so
/// web, updater and menu-bar modules can coordinate sheets and window levels
/// without importing `PlumeBubble`.
public protocol OverlayHost: AnyObject {
    /// Host window for system sheets (file/photo picker, delete confirm) while
    /// expanded; nil when the overlay card is folded away.
    var sheetHost: NSWindow? { get }

    /// Pause auto-collapse while a sheet or modal panel is presented over the
    /// overlay card, and re-focus the card when it finishes.
    func setModalPresentationActive(_ active: Bool)
}

/// Window level + Space membership for bubbles and the chat card.
///
/// `.statusWindow` / `.floating` sit *below* another app's fullscreen content.
/// `.screenSaver` is what actually stacks above a fullscreen Space.
/// Apple marks `.fullScreenPrimary`, `.fullScreenAuxiliary` and
/// `.canJoinAllApplications` as mutually exclusive: setting both auxiliary
/// and canJoinAllApplications left panels stuck on the desktop Space behind
/// another app's fullscreen window (visible again only after leaving it).
public enum PlumeOverlay {
    /// The currently active overlay host (set by bubble mode on show, cleared on hide).
    public static weak var activeHost: OverlayHost?

    /// True while overlay (bubble) mode is active.
    public static var isActive: Bool { activeHost != nil }

    public static let level = NSWindow.Level.screenSaver

    /// Join-all Spaces + Stage Manager / fullscreen overlays. No
    /// `.fullScreenAuxiliary` — mutually exclusive with `.canJoinAllApplications`.
    public static var collectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .canJoinAllApplications]
    }

    public static func apply(to window: NSWindow) {
        window.level = level
        window.collectionBehavior = collectionBehavior
        window.hidesOnDeactivate = false
    }

    /// Lift a standalone window (e.g. a call popup) onto the overlay Space tier
    /// when overlay mode is active, without changing its `hidesOnDeactivate`.
    public static func applyIfActive(to window: NSWindow) {
        guard isActive else { return }
        window.level = level
        window.collectionBehavior = collectionBehavior
    }
}

/// Raises AppKit menu windows above Plume's `.screenSaver` bubbles. Without
/// this, `NSMenu.popUp` opens at `.popUpMenu` (~101) and is invisible under
/// the chain — which looks exactly like "right-click does nothing".
public final class ChipMenuLift: NSObject, NSMenuDelegate {
    /// NSMenu.delegate is weak; this keeps the one stateless instance alive.
    public static let shared = ChipMenuLift()

    public func menuWillOpen(_ menu: NSMenu) {
        ChipMenuLift.elevateOpenMenus()
        // Submenus / delayed presentation need another pass next turn.
        DispatchQueue.main.async { ChipMenuLift.elevateOpenMenus() }
    }

    public static func elevateOpenMenus() {
        let target = NSWindow.Level(rawValue: PlumeOverlay.level.rawValue + 1)
        for window in NSApp.windows {
            let lvl = window.level.rawValue
            // Default menu / submenu windows; also catch private NSMenu subclasses.
            if lvl == NSWindow.Level.popUpMenu.rawValue
                || lvl == NSWindow.Level.tornOffMenu.rawValue
                || window.className.contains("Menu") {
                window.level = target
                window.collectionBehavior = PlumeOverlay.collectionBehavior
                window.hidesOnDeactivate = false
                window.orderFrontRegardless()
            }
        }
    }
}
