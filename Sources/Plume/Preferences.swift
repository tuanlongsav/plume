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

    /// Plume indigo accent theming (tầng B). Defaults to on.
    static var accent: Bool {
        get { defaults.object(forKey: "plume.accent") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.accent") }
    }

    /// Show the native toolbar chrome. Defaults to on; off ⇒ zero-chrome.
    static var toolbarVisible: Bool {
        get { defaults.object(forKey: "plume.toolbar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.toolbar") }
    }
}
