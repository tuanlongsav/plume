import AppKit

/// Window level + Space membership for bubbles and the chat card.
///
/// `.statusWindow` / `.floating` sit *below* another app's fullscreen content.
/// `.screenSaver` is what actually stacks above a fullscreen Space; combined
/// with `fullScreenAuxiliary` + `canJoinAllSpaces` the panel joins that Space
/// instead of staying on the desktop Space behind it.
enum PlumeOverlay {
    static let level = NSWindow.Level.screenSaver

    static var collectionBehavior: NSWindow.CollectionBehavior {
        var b: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]
        if #available(macOS 15.0, *) {
            b.insert(.canJoinAllApplications)
        }
        return b
    }

    static func apply(to window: NSWindow) {
        window.level = level
        window.collectionBehavior = collectionBehavior
        window.hidesOnDeactivate = false
    }
}

/// Raises AppKit menu windows above Plume's `.screenSaver` bubbles. Without
/// this, `NSMenu.popUp` opens at `.popUpMenu` (~101) and is invisible under
/// the chain — which looks exactly like "right-click does nothing".
final class ChipMenuLift: NSObject, NSMenuDelegate {
    /// NSMenu.delegate is weak; this keeps the one stateless instance alive.
    static let shared = ChipMenuLift()

    func menuWillOpen(_ menu: NSMenu) {
        ChipMenuLift.elevateOpenMenus()
        // Submenus / delayed presentation need another pass next turn.
        DispatchQueue.main.async { ChipMenuLift.elevateOpenMenus() }
    }

    static func elevateOpenMenus() {
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
