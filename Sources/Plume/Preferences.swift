import Foundation

/// Persisted UI preferences (UserDefaults). Window frame is handled separately
/// by `setFrameAutosaveName`.
enum Preferences {
    private static let defaults = UserDefaults.standard

    /// Force dark native appearance (web content follows via prefers-color-scheme).
    /// nil ⇒ follow the system.
    static var forceDark: Bool? {
        get { defaults.object(forKey: "plume.forceDark") as? Bool }
        set { defaults.set(newValue, forKey: "plume.forceDark") }
    }

    static var compact: Bool {
        get { defaults.bool(forKey: "plume.compact") }
        set { defaults.set(newValue, forKey: "plume.compact") }
    }

    /// Master kill switch for all injected tầng-B CSS. Off ⇒ remove every
    /// Plume style layer (escape hatch if a selector breaks Messenger's
    /// layout after a DOM change). Defaults to on.
    static var webStyling: Bool {
        get { defaults.object(forKey: "plume.webStyling") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.webStyling") }
    }

    /// Show the native toolbar chrome. Defaults to on; off ⇒ zero-chrome.
    static var toolbarVisible: Bool {
        get { defaults.object(forKey: "plume.toolbar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.toolbar") }
    }

    /// Keep the window floating above other apps. Defaults to off.
    static var alwaysOnTop: Bool {
        get { defaults.bool(forKey: "plume.alwaysOnTop") }
        set { defaults.set(newValue, forKey: "plume.alwaysOnTop") }
    }

    /// How many contact bubbles the chain may hold, newest first.
    static var bubbleLimit: Int {
        get { (defaults.object(forKey: "plume.bubbleLimit") as? Int) ?? 5 }
        set { defaults.set(max(1, min(newValue, 12)), forKey: "plume.bubbleLimit") }
    }

    /// Resting diameter of a chat head. Everything else in the chain — the
    /// magnified size, the panel canvas and the spacing between heads — is
    /// derived from this, so the chain stays proportioned at any size.
    static var bubbleSize: CGFloat {
        get {
            guard let v = defaults.object(forKey: "plume.bubbleSize") as? Double else { return 46 }
            return CGFloat(v)
        }
        set { defaults.set(Double(max(32, min(newValue, 80))), forKey: "plume.bubbleSize") }
    }

    /// When true, the bubble chain teleports onto the display under the cursor.
    /// When false, heads stay where the user parked them (drag to move displays).
    /// Defaults to on — the previous always-follow behaviour.
    static var bubbleFollowActiveDisplay: Bool {
        get { defaults.object(forKey: "plume.bubbleFollowDisplay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.bubbleFollowDisplay") }
    }

    /// Was the app in bubble mode when it was last used? Restored on launch.
    static var bubbleMode: Bool {
        get { defaults.bool(forKey: "plume.bubbleMode") }
        set { defaults.set(newValue, forKey: "plume.bubbleMode") }
    }

    /// Conversation keyboard navigation (Caprine port). Defaults to on.
    static var shortcuts: Bool {
        get { defaults.object(forKey: "plume.shortcuts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.shortcuts") }
    }
}
