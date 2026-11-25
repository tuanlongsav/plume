import AppKit
import PlumeCore
import UserNotifications
import WebKit

/// Manages `WKDownload` attachments: temporary staging, in-app PDF viewing,
/// durable `~/Downloads` handoff for other files, and failure notifications.
public final class AttachmentDownloadManager: NSObject, WKDownloadDelegate {
    /// Throwaway view-copies of opened attachments live here.
    public static let downloadsDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlumeAttachments", isDirectory: true)

    /// Delete stale attachment copies — call once at launch. They're view-only
    /// (the user's durable copy is whatever they Save-a-Copy'd), no PDF window
    /// survives a relaunch, so nothing here is still needed.
    public static func clearDownloadCache() {
        try? FileManager.default.removeItem(at: downloadsDir)
    }

    /// Move a finished attachment into ~/Downloads under a free name
    /// ("name.ext", "name (2).ext", …). Returns nil if it can't.
    public static func moveToDownloads(_ file: URL) -> URL? {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return nil }
        let ext = file.pathExtension
        let stem = file.deletingPathExtension().lastPathComponent
        for n in 1...999 {
            let name = n == 1 ? file.lastPathComponent
                : (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            let dest = downloads.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { continue }
            guard (try? fm.moveItem(at: file, to: dest)) != nil else { return nil }
            // The per-download temp folder is empty now.
            try? fm.removeItem(at: file.deletingLastPathComponent())
            return dest
        }
        return nil
    }

    /// WebKit does not retain a WKDownload across its async destination/finish
    /// callbacks, so we hold each one (and its chosen destination) ourselves
    /// for the download's lifetime.
    private var activeDownloads: Set<WKDownload> = []
    private var downloadDestinations: [WKDownload: URL] = [:]
    /// Delays the (undimmed) download progress pill so instant downloads — the
    /// common case — don't flash it.
    private var downloadLoadingWork: DispatchWorkItem?

    /// Fired when the undimmed progress pill should appear (`true`) or clear (`false`).
    var onLoadingChanged: ((Bool) -> Void)?

    /// Hold the download and start delegating its callbacks to us.
    func beginDownload(_ download: WKDownload) {
        download.delegate = self          // delegate is weak…
        activeDownloads.insert(download)  // …so keep a strong reference here
        scheduleDownloadIndicator()
    }

    /// Show the progress pill (no dim) only if a download is still running after
    /// a short delay — most attachments finish instantly.
    private func scheduleDownloadIndicator() {
        guard downloadLoadingWork == nil else { return }   // one timer covers all
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.activeDownloads.isEmpty else { return }
            self.onLoadingChanged?(true)
        }
        downloadLoadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Called when a download finishes/fails; clears the pill once none remain.
    private func downloadEnded() {
        guard activeDownloads.isEmpty else { return }
        downloadLoadingWork?.cancel()
        downloadLoadingWork = nil
        onLoadingChanged?(false)
    }

    // MARK: WKDownloadDelegate

    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {
        // Per-download UUID subdir: duplicate filenames never collide and the
        // returned URL is guaranteed not to pre-exist (WebKit requires that).
        let dir = Self.downloadsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Defence in depth: the sender influences the filename, so strip any
        // path components (WebKit sanitises too, but never trust it) — a
        // "../../x" name must not escape the per-download temp dir.
        let leaf = (suggestedFilename as NSString).lastPathComponent
        let name = leaf.isEmpty ? "attachment" : leaf
        let dest = dir.appendingPathComponent(name)
        downloadDestinations[download] = dest
        completionHandler(dest)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let dest = downloadDestinations[download]
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        downloadEnded()
        guard let url = dest else { return }
        if url.pathExtension.lowercased() == "pdf" {
            PDFViewerWindowController.open(url)                   // native in-app viewer
        } else {
            // Revealing the temp copy looked like a finished download, but
            // `clearDownloadCache` deletes it at the next launch. Keep the file
            // where a browser would; fall back to the temp copy if that fails.
            let kept = Self.moveToDownloads(url) ?? url
            NSWorkspace.shared.activateFileViewerSelecting([kept])
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let filename = downloadDestinations[download]?.lastPathComponent
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
        downloadEnded()   // clears the progress pill once no download remains
        // A superseded download (another attachment click) cancels this one —
        // not worth surfacing. Everything else failed a user-requested open.
        if (error as NSError).code == NSURLErrorCancelled { return }
        notifyDownloadFailed(filename)
    }

    private func notifyDownloadFailed(_ filename: String?) {
        let content = UNMutableNotificationContent()
        content.title = L.t("Không tải được tệp", "Download failed")
        content.body = filename.map { L.t("Không tải được “\($0)”.", "Couldn't download “\($0)”.") }
            ?? L.t("Không tải được tệp đính kèm.", "Couldn't download the attachment.")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "plume-dlfail-\(UUID().uuidString)",
                                  content: content, trigger: nil),
            withCompletionHandler: nil)
    }
}
