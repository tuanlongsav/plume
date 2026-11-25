import AppKit
import PlumeCore

/// Outbound URL handoff shared by the main web view and call/popup windows.
public enum ExternalLinkOpener {
    public static func open(_ url: URL) {
        guard Plume.isExternallyOpenable(url) else { return }
        NSWorkspace.shared.open(Plume.unwrapLinkShim(url))
    }
}
