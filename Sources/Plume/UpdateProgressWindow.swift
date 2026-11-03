import AppKit

/// A small floating panel with the download progress and a Cancel button.
/// Its own window, so it works while the main window is hidden in bubble mode.
final class UpdateProgressWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let onCancel: () -> Void

    init(version: AppVersion, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 112),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Plume"
        panel.isReleasedWhenClosed = false
        panel.level = ChatBubbleController.isOpen ? .screenSaver : .floating
        panel.delegate = self

        label.stringValue = L.t("Đang tải Plume \(version)…", "Downloading Plume \(version)…")
        label.frame = NSRect(x: 20, y: 74, width: 340, height: 18)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 20, y: 48, width: 340, height: 20)
        cancelButton.title = L.t("Huỷ", "Cancel")
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.frame = NSRect(x: 262, y: 8, width: 104, height: 32)

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        for view in [label, bar, cancelButton] as [NSView] { content.addSubview(view) }
        panel.contentView = content
    }

    func show() {
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func setFraction(_ fraction: Double) {
        bar.doubleValue = min(max(fraction, 0), 1)
    }

    func showInstalling() {
        label.stringValue = L.t("Đang kiểm tra và cài đặt…", "Verifying and installing…")
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        cancelButton.isEnabled = false
    }

    func close() {
        panel.delegate = nil
        bar.stopAnimation(nil)
        panel.orderOut(nil)
    }

    @objc private func cancel() { onCancel() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard cancelButton.isEnabled else { return false }   // too late to stop an install
        onCancel()
        return false   // the Updater closes it once the download has stopped
    }
}
