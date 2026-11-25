import AppKit

/// Overlay-aware `NSAlert` presentation shared across App, Web and Updater.
///
/// Centralises activating Plume and lifting modal alerts above `.screenSaver`
/// bubbles when overlay mode is active, as well as bracketing `OverlayHost`
/// sheet presentation so a sheet does not fold the bubble card underneath it.
public enum AlertPresenter {
    /// Present an app-modal alert, raised above `.screenSaver` overlays when
    /// bubble mode is active. Empty `buttons` shows a single OK button.
    @discardableResult
    public static func presentModal(title: String,
                                    detail: String,
                                    buttons: [String] = [],
                                    style: NSAlert.Style = .informational,
                                    userInitiated: Bool = true,
                                    fromShortcut: Bool = false) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        if fromShortcut {
            NSApp.plumeActivate(fromShortcut: true)
        } else {
            NSApp.plumeActivate(userInitiated: userInitiated)
        }
        if PlumeOverlay.isActive { alert.window.level = PlumeOverlay.level }
        return alert.runModal()
    }

    /// Present `alert` as a sheet on the active overlay card or `preferredHost`
    /// when visible; otherwise run it app-modal raised above overlays so a
    /// sheet on an off-screen window never stalls silently.
    public static func presentSheetOrModal(_ alert: NSAlert,
                                           preferredHost: NSWindow?,
                                           holdOverlay: Bool = false,
                                           requireAppActiveForSheet: Bool = false,
                                           activateFromShortcutOnFallback: Bool = false,
                                           alwaysLiftFallback: Bool = false,
                                           completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let overlayHost = PlumeOverlay.activeHost
        if holdOverlay { overlayHost?.setModalPresentationActive(true) }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if holdOverlay { overlayHost?.setModalPresentationActive(false) }
            completion?(response)
        }

        let candidate = overlayHost?.sheetHost ?? preferredHost
        let canUseSheet = (candidate?.isVisible == true) && (!requireAppActiveForSheet || NSApp.isActive)
        if canUseSheet, let host = candidate {
            alert.beginSheetModal(for: host, completionHandler: finish)
        } else {
            if activateFromShortcutOnFallback {
                NSApp.plumeActivate(fromShortcut: true)
            }
            if alwaysLiftFallback || PlumeOverlay.isActive {
                alert.window.level = PlumeOverlay.level
            }
            let response = alert.runModal()
            finish(response)
        }
    }
}
