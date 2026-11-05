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

    /// Page zoom of the main window (View ▸ Zoom In/Out, ⌘+ ⌘− ⌘0).
    /// Defaults to 1; whatever is stored is clamped to `PageZoom.levels`.
    static var pageZoom: Double {
        get { PageZoom.clamped(defaults.object(forKey: "plume.pageZoom") as? Double ?? PageZoom.actual) }
        set { defaults.set(PageZoom.clamped(newValue), forKey: "plume.pageZoom") }
    }

    /// Block third-party ad and analytics hosts (`TrackerRules`). Defaults to
    /// on: the list holds nothing Messenger needs.
    static var blockTrackers: Bool {
        get { defaults.object(forKey: "plume.blockTrackers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.blockTrackers") }
    }

    /// Show no unread count on the Dock icon, the menu bar icon or the app
    /// chip, for when a number waiting is itself a distraction. Defaults to
    /// off. Notifications still arrive.
    static var hideUnreadCount: Bool {
        get { defaults.bool(forKey: "plume.hideUnreadCount") }
        set { defaults.set(newValue, forKey: "plume.hideUnreadCount") }
    }

    /// Show Plume's icon (and unread count) in the menu bar, and keep running
    /// in it when the main window is closed. Defaults to off.
    static var menuBarIcon: Bool {
        get { defaults.bool(forKey: "plume.menuBarIcon") }
        set { defaults.set(newValue, forKey: "plume.menuBarIcon") }
    }

    /// Register `Summon.hotKeyLabel` system-wide. Defaults to off: a global
    /// shortcut takes the key from every other app.
    static var globalHotKey: Bool {
        get { defaults.bool(forKey: "plume.globalHotKey") }
        set { defaults.set(newValue, forKey: "plume.globalHotKey") }
    }

    /// Keep the window floating above other apps. Defaults to off.
    static var alwaysOnTop: Bool {
        get { defaults.bool(forKey: "plume.alwaysOnTop") }
        set { defaults.set(newValue, forKey: "plume.alwaysOnTop") }
    }

    /// Values offered for `bubbleLimit`. Shared by the Window menu and the
    /// bubble chip menu, which used to offer different lists.
    static let bubbleLimitChoices = [3, 5, 8, 12]

    /// How many contact bubbles the chain may hold, newest first.
    static var bubbleLimit: Int {
        get { (defaults.object(forKey: "plume.bubbleLimit") as? Int) ?? 5 }
        set { defaults.set(max(1, min(newValue, bubbleLimitChoices.max() ?? 12)), forKey: "plume.bubbleLimit") }
    }

    /// Values offered for `bubbleSize`, with their menu labels (vi, en).
    static let bubbleSizeChoices: [(vi: String, en: String, size: Int)] = [
        ("Nhỏ", "Small", 38), ("Vừa", "Medium", 46),
        ("Lớn", "Large", 56), ("Rất lớn", "Extra Large", 66),
    ]

    /// Resting diameter of a chat head. Everything else in the chain — the
    /// magnified size, the panel canvas and the spacing between heads — is
    /// derived from this, so the chain stays proportioned at any size.
    /// Cached: the chain's geometry reads it many times per animation frame.
    static var bubbleSize: CGFloat {
        get {
            if let v = cachedBubbleSize { return v }
            let v = (defaults.object(forKey: "plume.bubbleSize") as? Double).map { CGFloat($0) } ?? 46
            cachedBubbleSize = v
            return v
        }
        set {
            let v = max(32, min(newValue, 80))
            defaults.set(Double(v), forKey: "plume.bubbleSize")
            cachedBubbleSize = v
        }
    }
    private static var cachedBubbleSize: CGFloat?

    /// Content size the user last gave the bubble card; nil until resized.
    /// Content, not frame, size: restoring a frame size with `setContentSize`
    /// drifts by the titlebar's height on every open.
    static var bubbleCardSize: NSSize? {
        get {
            guard let d = defaults.dictionary(forKey: "plume.bubbleCardSize2"),
                  let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
            return NSSize(width: w, height: h)
        }
        set {
            guard let v = newValue else { defaults.removeObject(forKey: "plume.bubbleCardSize2"); return }
            defaults.set(["w": Double(v.width), "h": Double(v.height)], forKey: "plume.bubbleCardSize2")
        }
    }

    /// Screen position of the chain's head (the app chip); nil until moved.
    static var bubbleOrigin: NSPoint? {
        get {
            guard let d = defaults.dictionary(forKey: "plume.bubbleOrigin"),
                  let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            guard let v = newValue else { defaults.removeObject(forKey: "plume.bubbleOrigin"); return }
            defaults.set(["x": Double(v.x), "y": Double(v.y)], forKey: "plume.bubbleOrigin")
        }
    }

    /// When true, the bubble chain teleports onto the display under the cursor.
    /// When false, heads stay where the user parked them (drag to move displays).
    /// Defaults to on — the previous always-follow behaviour.
    static var bubbleFollowActiveDisplay: Bool {
        get { defaults.object(forKey: "plume.bubbleFollowDisplay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.bubbleFollowDisplay") }
    }

    /// The Messenger site the account was last seen on. Meta moves accounts
    /// from messenger.com to facebook.com/messages one at a time; once moved,
    /// starting on messenger.com costs a redirect at best.
    static var messengerSite: ThreadURL.Site {
        get { defaults.string(forKey: "plume.surface") == "facebook" ? .facebook : .messenger }
        set { defaults.set(newValue == .facebook ? "facebook" : "messenger", forKey: "plume.surface") }
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

    // MARK: Updates (see Updater)

    /// Look for a new release once a day. Defaults to on.
    static var autoUpdateCheck: Bool {
        get { defaults.object(forKey: "plume.autoUpdateCheck") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "plume.autoUpdateCheck") }
    }

    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "plume.lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "plume.lastUpdateCheck") }
    }

    /// "Skip This Version": automatic checks stay quiet about this one.
    static var skippedVersion: String? {
        get { defaults.string(forKey: "plume.skippedVersion") }
        set { defaults.set(newValue, forKey: "plume.skippedVersion") }
    }

    /// Set just before relaunching into a new version, so that version can
    /// say it was updated — once.
    static var pendingUpdateNotice: String? {
        get { defaults.string(forKey: "plume.pendingUpdateNotice") }
        set { defaults.set(newValue, forKey: "plume.pendingUpdateNotice") }
    }

    /// `owner/name` of the GitHub repository releases come from. Hidden: it
    /// exists for dry runs against a scratch repository
    /// (`defaults write com.htl.plume plume.updateRepo owner/name`). Signature
    /// and Developer ID checks apply whatever it says.
    static var updateRepo: String {
        defaults.string(forKey: "plume.updateRepo") ?? UpdateFeed.defaultRepo
    }
}
