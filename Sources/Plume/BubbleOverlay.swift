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
        // .canJoinAllApplications keeps the panels over another app's
        // full-screen Space and in Stage Manager. Its symbol first appeared in
        // the macOS 15 SDK, which is why it was gated on 15, but the SDK
        // declares it available from 13.0, so every supported system gets it.
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
         .canJoinAllApplications]
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
