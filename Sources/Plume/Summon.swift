import Foundation

/// What the menu bar icon and the global shortcut do: bring Plume up, or put
/// it away when it is already what the user is looking at.
///
/// Kept apart from AppKit so the decision is testable. Bubble mode is not
/// decided here: there the main window is hidden on purpose, and the
/// shortcut folds or unfolds the bubble card instead.
enum Summon {
    enum Action: Equatable { case show, hide }

    /// Hide only when Plume is frontmost AND its main window is the key one;
    /// in every other state (another app in front, Plume hidden, the window
    /// closed or minimised, a PDF or call window key) the user wants the
    /// chats in front of them.
    static func action(appActive: Bool, appHidden: Bool,
                       mainWindowVisible: Bool, mainWindowKey: Bool) -> Action {
        appActive && !appHidden && mainWindowVisible && mainWindowKey ? .hide : .show
    }

    /// ⌃⌥⌘M. Not ⌃⌥Space or ⌃Space: those switch input sources, which a
    /// Vietnamese typist uses all day. Not ⌥⌘M (Minimise All) or ⌘⇧Y
    /// (New Sticky Note): taken system-wide.
    static let hotKeyCode: UInt32 = 0x2E            // kVK_ANSI_M
    static let hotKeyLabel = "⌃⌥⌘M"

    /// The unread count beside the menu bar icon: the Dock badge's text, and
    /// nothing at all at zero so the icon stays narrow.
    static func statusTitle(unread: Int, hidden: Bool = false) -> String {
        WebViewController.badgeLabel(unread, hidden: hidden) ?? ""
    }
}
