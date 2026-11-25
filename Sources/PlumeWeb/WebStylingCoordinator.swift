import AppKit
import PlumeCore
import WebKit

/// Owns appearance overrides (Dark / Light / System), tầng-B CSS toggles
/// (Compact / Web Styling), and the third-party WebKit content blocker.
public final class WebStylingCoordinator {
    private weak var webView: WKWebView?
    private weak var pageBridge: MessengerPageBridge?
    private var trackerList: WKContentRuleList?

    var onChromeUpdate: (() -> Void)?

    func attach(webView: WKWebView, pageBridge: MessengerPageBridge) {
        self.webView = webView
        self.pageBridge = pageBridge
    }

    // MARK: Native appearance

    public static func applyAppearance() {
        switch Preferences.forceDark {
        case .some(true):  NSApp.appearance = NSAppearance(named: .darkAqua)
        case .some(false): NSApp.appearance = NSAppearance(named: .aqua)
        case .none:        NSApp.appearance = nil
        }
    }

    var isDarkForced: Bool { Preferences.forceDark == true }

    func toggleDark() {
        Preferences.forceDark = (Preferences.forceDark == true) ? false : true
        Self.applyAppearance()
        onChromeUpdate?()
    }

    func followSystemAppearance() {
        Preferences.forceDark = nil
        Self.applyAppearance()
        onChromeUpdate?()
    }

    // MARK: Tầng-B CSS theming

    var isCompact: Bool { Preferences.compact }

    func toggleCompact() {
        Preferences.compact.toggle()
        applyDensity()
        onChromeUpdate?()
    }

    var isWebStyling: Bool { Preferences.webStyling }

    func toggleWebStyling() {
        Preferences.webStyling.toggle()
        applyWebTheme()
        onChromeUpdate?()
    }

    /// Apply base + current toggle state. Called once each successful load.
    /// The master `webStyling` switch strips every layer when off.
    func applyWebTheme() {
        guard Preferences.webStyling else {
            pageBridge?.removeStyle(id: InjectedScript.StyleID.density)
            return
        }
        applyDensity()
    }

    private func applyDensity() {
        if Preferences.webStyling, Preferences.compact {
            pageBridge?.setStyle(id: InjectedScript.StyleID.density, css: InjectedScript.densityCSS)
        } else {
            pageBridge?.removeStyle(id: InjectedScript.StyleID.density)
        }
    }

    // MARK: Tracker blocking

    var isBlockingTrackers: Bool { Preferences.blockTrackers }

    /// Compile `TrackerRules` and attach it, then `done`. WebKit compiles off
    /// the main thread and keeps the result under the identifier; the first
    /// page load waits for it so the blocker covers that load too. `done` runs
    /// once even if the store fails, so the page always loads.
    func prepareTrackerBlocking(then done: @escaping () -> Void) {
        guard let store = WKContentRuleListStore.default() else { done(); return }
        store.compileContentRuleList(forIdentifier: TrackerRules.identifier,
                                     encodedContentRuleList: TrackerRules.json()) { [weak self] list, _ in
            DispatchQueue.main.async {
                self?.trackerList = list
                self?.applyTrackerBlocking()
                done()
            }
        }
    }

    func toggleBlockTrackers() {
        Preferences.blockTrackers.toggle()
        applyTrackerBlocking()
    }

    /// On the shared content controller, so call windows opened from the
    /// page get it too. Takes effect from the next request.
    private func applyTrackerBlocking() {
        guard let list = trackerList, let webView else { return }
        let content = webView.configuration.userContentController
        content.remove(list)
        if Preferences.blockTrackers { content.add(list) }
    }
}
