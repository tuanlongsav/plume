import AppKit

// SwiftPM executables can't use @main with AppKit cleanly, so we boot
// NSApplication by hand. This is the entire process entry point.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
