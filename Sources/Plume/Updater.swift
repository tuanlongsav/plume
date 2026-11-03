import AppKit
import Security
import UserNotifications

/// Self-update from GitHub Releases, without Sparkle.
///
/// Trust is the same as Sparkle's: the zip must carry an Ed25519 signature by
/// the key in `UpdateKeys`, and the unpacked app must be signed by Plume's
/// Developer ID team. The only request ever made is an unauthenticated
/// `releases/latest` (plus the asset downloads when the user says Update),
/// with no cookies and nothing but a User-Agent — at most once a day.
///
/// No timers: one delayed check after launch, then `checkIfDue` on app
/// activation, which is a date comparison until a day has passed (rule 7).
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    enum Eligibility: Equatable {
        case ok, devBuild, noPublicKey, notDeveloperID
        case translocated, readOnlyVolume, notWritable
    }

    private static let bundleID = "com.htl.plume"
    /// Plume's Developer ID: Apple-anchored, a Developer ID leaf (the two
    /// OIDs), team U4B264GM2B. `codesign --verify` alone would also accept an
    /// ad-hoc signature, which proves nothing about who built the app.
    private static let requirementText =
        "anchor apple generic and identifier \"\(bundleID)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"U4B264GM2B\""
    private static let stagingName = ".Plume-update"
    private static let launchDelay: TimeInterval = 20

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        let version = AppVersion.current?.description ?? "dev"
        config.httpAdditionalHeaders = ["User-Agent": "Plume/\(version) (macOS)"]
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Set once the launch delay has passed; activation checks wait for it so
    /// the first launch does not hit the network while the page is loading.
    private var armed = false
    /// A check, download or install is under way.
    private var busy = false
    private var job: (candidate: UpdateCandidate, manifest: UpdateManifest)?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedZip: URL?
    private var progress: UpdateProgressWindow?

    // MARK: Entry points

    func scheduleLaunchCheck() {
        removeLeftoverStaging()
        showPostUpdateNoticeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.armed = true
            self?.checkIfDue()
        }
    }

    /// Automatic check: silent unless there is something to offer.
    func checkIfDue() {
        guard armed, !busy, Preferences.autoUpdateCheck,
              UpdateSchedule.isDue(last: Preferences.lastUpdateCheck),
              Self.eligibility() == .ok
        else { return }
        Preferences.lastUpdateCheck = Date()
        check(manual: false)
    }

    /// Plume ▸ Check for Updates…: always answers, ignores "Skip This Version".
    @objc func checkNow(_ sender: Any?) {
        if busy {
            progress?.bringToFront()
            return
        }
        let eligibility = Self.eligibility()
        guard eligibility == .ok else { explainIneligible(eligibility); return }
        Preferences.lastUpdateCheck = Date()
        check(manual: true)
    }

    // MARK: Eligibility

    static func eligibility() -> Eligibility {
        guard let current = AppVersion.current, !current.isDev else { return .devBuild }
        guard UpdateKeys.publicKey != nil else { return .noPublicKey }
        // Replacing an ad-hoc build with a Developer ID one changes its
        // designated requirement, and macOS re-asks for camera and microphone.
        guard runningAppIsDeveloperID else { return .notDeveloperID }
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") { return .translocated }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: app.path)
        else { return .notWritable }
        return .ok
    }

    /// The signature of the running code cannot change underneath it.
    private static let runningAppIsDeveloperID: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let requirement = makeRequirement()
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }()

    private static func makeRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: Check

    private func check(manual: Bool) {
        guard let current = AppVersion.current,
              let url = UpdateFeed.latestReleaseURL(repo: Preferences.updateRepo)
        else { return }
        busy = true
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        session.dataTask(with: request) { [weak self] data, response, error in
            Self.onRunLoop { self?.handleCheck(data: data, response: response, error: error,
                                               current: current, manual: manual) }
        }.resume()
    }

    private func handleCheck(data: Data?, response: URLResponse?, error: Error?,
                             current: AppVersion, manual: Bool) {
        busy = false
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404: the repository has no published release yet.
        if status == 404 {
            if manual { showUpToDate(current) }
            return
        }
        guard error == nil, status == 200, let data,
              let release = try? JSONDecoder().decode(UpdateRelease.self, from: data)
        else {
            if manual { showFailure(.checkFailed) }
            return
        }
        let skipped = Preferences.skippedVersion.flatMap(AppVersion.init)
        switch UpdateFeed.decide(release: release, current: current,
                                 skipped: skipped, honourSkip: !manual) {
        case .upToDate:
            if manual { showUpToDate(current) }
        case .skipped:
            break
        case .assetsMissing(let version, let page):
            if manual { showFailure(.assetsMissing(version), page: page) }
        case .available(let candidate):
            offer(candidate, current: current, manual: manual)
        }
    }

    /// URLSession calls back inside a main-queue block. A modal alert run
    /// there would hold the main queue for as long as it is open, stalling
    /// every `DispatchQueue.main` callback in the app; a run-loop block does not.
    private static func onRunLoop(_ work: @escaping () -> Void) {
        RunLoop.main.perform(work)
    }

    private func offer(_ candidate: UpdateCandidate, current: AppVersion, manual: Bool) {
        let alert = NSAlert()
        alert.messageText = L.t("Có bản \(candidate.title)", "\(candidate.title) is available")
        let installed = L.t("Bạn đang dùng Plume \(current).", "You have Plume \(current).")
        alert.informativeText = candidate.notes.isEmpty
            ? installed : candidate.notes + "\n\n" + installed
        alert.addButton(withTitle: L.t("Cập nhật", "Update"))
        alert.addButton(withTitle: L.t("Để sau", "Later"))
        if !manual {
            alert.addButton(withTitle: L.t("Bỏ qua phiên bản này", "Skip This Version"))
        }
        switch present(alert) {
        case .alertFirstButtonReturn:
            Preferences.skippedVersion = nil
            fetchManifest(for: candidate)
        case .alertThirdButtonReturn:
            Preferences.skippedVersion = candidate.version.description
        default:
            break
        }
    }

    // MARK: Download

    private func fetchManifest(for candidate: UpdateCandidate) {
        busy = true
        session.dataTask(with: candidate.manifestURL) { [weak self] data, response, error in
            Self.onRunLoop { self?.handleManifest(data: data, response: response, error: error,
                                                  candidate: candidate) }
        }.resume()
    }

    private func handleManifest(data: Data?, response: URLResponse?, error: Error?,
                                candidate: UpdateCandidate) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, status == 200, let data, data.count <= 64 * 1024,
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data)
        else {
            finishWithFailure(.downloadFailed, page: candidate.pageURL)
            return
        }
        do {
            try UpdateVerifier.checkManifest(
                manifest, expectedVersion: candidate.version,
                assetName: UpdateFeed.assetNames(for: candidate.version).zip,
                assetSize: candidate.zipSize)
        } catch {
            PlumeTrace.log("update: manifest rejected: \(error)")
            finishWithFailure(.invalidPackage, page: candidate.pageURL)
            return
        }
        guard SystemVersion.satisfies(minimum: manifest.minimumSystemVersion,
                                      running: ProcessInfo.processInfo.operatingSystemVersion)
        else {
            finishWithFailure(.needsNewerSystem(manifest.minimumSystemVersion),
                              page: candidate.pageURL)
            return
        }
        startDownload(candidate, manifest: manifest)
    }

    private func startDownload(_ candidate: UpdateCandidate, manifest: UpdateManifest) {
        job = (candidate, manifest)
        downloadedZip = nil
        let task = session.downloadTask(with: candidate.zipURL)
        downloadTask = task
        progress = UpdateProgressWindow(version: candidate.version) { [weak self] in
            self?.downloadTask?.cancel()
        }
        progress?.show()
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard downloadTask === self.downloadTask, let job else { return }
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite : Int64(job.manifest.length)
        progress?.setFraction(Double(totalBytesWritten) / Double(max(total, 1)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard downloadTask === self.downloadTask,
              (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        // `location` is deleted as soon as this returns: move it out now.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-update-\(UUID().uuidString)", isDirectory: true)
        let zip = dir.appendingPathComponent("Plume.zip")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zip)
            downloadedZip = zip
        } catch {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === downloadTask, let job else { return }
        downloadTask = nil
        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            finishQuietly()
            return
        }
        guard error == nil, let zip = downloadedZip else {
            Self.onRunLoop { self.finishWithFailure(.downloadFailed, page: job.candidate.pageURL) }
            return
        }
        install(zip: zip, candidate: job.candidate, manifest: job.manifest)
    }

    // MARK: Install

    private func install(zip: URL, candidate: UpdateCandidate, manifest: UpdateManifest) {
        progress?.showInstalling()
        let installed = Bundle.main.bundleURL
        let staging = installed.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingName, isDirectory: true)
        // Hashing, unzipping and the signature check take a few seconds on a
        // universal binary; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, UpdateFailure>
            do {
                guard let key = UpdateKeys.publicKey else { throw UpdateFailure.invalidPackage }
                let data = try Data(contentsOf: zip, options: .mappedIfSafe)
                try UpdateVerifier.verifyArchive(data, manifest: manifest, publicKey: key)
                let app = try Self.unpack(zip, into: staging)
                try Self.verifyBundle(app, expected: candidate.version)
                result = .success(app)
            } catch {
                PlumeTrace.log("update: install rejected: \(error)")
                try? FileManager.default.removeItem(at: staging)
                result = .failure(error as? UpdateFailure ?? .invalidPackage)
            }
            try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
            Self.onRunLoop {
                switch result {
                case .success(let app): self.swapAndRelaunch(staged: app, installed: installed,
                                                             staging: staging, version: candidate.version,
                                                             page: candidate.pageURL)
                case .failure(let failure): self.finishWithFailure(failure, page: candidate.pageURL)
                }
            }
        }
    }

    /// `ditto` is what made the zip; it restores the bundle's symlinks and
    /// extended attributes exactly. Only ever run on an archive whose
    /// signature has already been verified.
    private static func unpack(_ zip: URL, into staging: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = staging.appendingPathComponent("Plume.app", isDirectory: true)
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: app.path) else {
            throw UpdateFailure.invalidPackage
        }
        return app
    }

    /// The unpacked app must be Plume, the version the release promised, able
    /// to run here, and signed by Plume's Developer ID.
    private static func verifyBundle(_ app: URL, expected: AppVersion) throws {
        // Read the plist directly: `Bundle(url:)` caches by path.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              info["CFBundleIdentifier"] as? String == bundleID,
              (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == expected
        else { throw UpdateFailure.invalidPackage }
        if let minimum = info["LSMinimumSystemVersion"] as? String,
           !SystemVersion.satisfies(minimum: minimum,
                                    running: ProcessInfo.processInfo.operatingSystemVersion) {
            throw UpdateFailure.needsNewerSystem(minimum)
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = makeRequirement()
        else { throw UpdateFailure.invalidPackage }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)
                                    | UInt32(kSecCSCheckAllArchitectures)
                                    | UInt32(kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateFailure.invalidPackage
        }
    }

    /// Swap the verified app into place in one atomic rename, so there is
    /// never a moment with no Plume.app; then quit and let a detached shell
    /// reopen it. The running binary keeps working after its bundle moves.
    private func swapAndRelaunch(staged: URL, installed: URL, staging: URL,
                                 version: AppVersion, page: URL) {
        do {
            try Self.swap(staged, into: installed)
        } catch {
            PlumeTrace.log("update: swap failed: \(error)")
            try? FileManager.default.removeItem(at: staging)
            finishWithFailure(.installFailed, page: page)
            return
        }
        Preferences.pendingUpdateNotice = version.description
        // $1 pid, $2 staging dir (now holding the old app), $3 the app.
        // Waits up to a minute for this process to exit; if quitting was
        // cancelled it does not reopen anything — the new version is already
        // in place for the next launch, which also clears the staging dir.
        let script = """
        ( i=0; while kill -0 "$1" 2>/dev/null; do \
        [ "$i" -ge 300 ] && exit 0; sleep 0.2; i=$((i+1)); done; \
        rm -rf "$2"; /usr/bin/open "$3" ) >/dev/null 2>&1 &
        """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh",
                           String(ProcessInfo.processInfo.processIdentifier),
                           staging.path, installed.path]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
        } catch {
            // Installed but not relaunched: say so rather than quit silently.
            finishQuietly()
            let alert = NSAlert()
            alert.messageText = L.t("Đã cài Plume \(version)", "Plume \(version) is installed")
            alert.informativeText = L.t("Thoát và mở lại Plume để dùng bản mới.",
                                        "Quit and reopen Plume to use it.")
            present(alert)
            return
        }
        progress?.close()
        progress = nil
        NSApp.terminate(nil)
    }

    private static func swap(_ staged: URL, into installed: URL) throws {
        let rc = staged.withUnsafeFileSystemRepresentation { from in
            installed.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_SWAP))
            }
        }
        if rc == 0 { return }
        // Some file systems (e.g. network volumes) cannot swap; fall back to
        // a replace, which is not atomic but keeps a consistent result.
        guard errno == ENOTSUP || errno == EINVAL else { throw UpdateFailure.installFailed }
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
    }

    // MARK: Housekeeping

    private func removeLeftoverStaging() {
        let staging = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingName, isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    private func showPostUpdateNoticeIfNeeded() {
        guard let pending = Preferences.pendingUpdateNotice else { return }
        Preferences.pendingUpdateNotice = nil
        guard let current = AppVersion.current, AppVersion(pending) == current else { return }
        let content = UNMutableNotificationContent()
        content.title = L.t("Đã cập nhật lên Plume \(current)", "Updated to Plume \(current)")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "plume.updated", content: content, trigger: nil))
    }

    private func finishQuietly() {
        busy = false
        job = nil
        downloadTask = nil
        if let zip = downloadedZip {
            try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
        }
        downloadedZip = nil
        progress?.close()
        progress = nil
    }

    // MARK: Alerts

    private func finishWithFailure(_ failure: UpdateFailure, page: URL?) {
        finishQuietly()
        showFailure(failure, page: page)
    }

    private func showFailure(_ failure: UpdateFailure, page: URL? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.detail
        alert.addButton(withTitle: "OK")
        let page = page ?? UpdateFeed.releasesPageURL(repo: Preferences.updateRepo)
        if page != nil {
            alert.addButton(withTitle: L.t("Mở trang tải về", "Open Download Page"))
        }
        if present(alert) == .alertSecondButtonReturn, let page {
            NSWorkspace.shared.open(page)
        }
    }

    private func showUpToDate(_ current: AppVersion) {
        let alert = NSAlert()
        alert.messageText = L.t("Bạn đang dùng bản mới nhất", "You're up to date")
        alert.informativeText = L.t("Plume \(current) là phiên bản mới nhất.",
                                    "Plume \(current) is the newest version.")
        present(alert)
    }

    private func explainIneligible(_ reason: Eligibility) {
        let detail: String
        switch reason {
        case .ok: return
        case .devBuild, .notDeveloperID:
            detail = L.t("Đây là bản build cục bộ. Chỉ bản phát hành chính thức mới tự cập nhật.",
                         "This is a local build. Only official releases update themselves.")
        case .noPublicKey:
            detail = L.t("Bản này chưa được cấu hình khoá cập nhật.",
                         "This build has no update key configured.")
        case .translocated, .readOnlyVolume:
            detail = L.t("Plume đang chạy từ ảnh đĩa hoặc thư mục tải về. Hãy kéo Plume vào thư mục Applications rồi mở lại.",
                         "Plume is running from a disk image or the Downloads folder. Move it to Applications and open it again.")
        case .notWritable:
            detail = L.t("Tài khoản này không có quyền ghi vào thư mục chứa Plume.",
                         "This account cannot write to the folder Plume is in.")
        }
        showFailure(UpdateFailure.ineligible(detail))
    }

    /// App-modal: in bubble mode the main window is hidden, so a sheet would
    /// never appear. Raised above the `.screenSaver`-level bubbles then.
    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        if ChatBubbleController.isOpen { alert.window.level = .screenSaver }
        return alert.runModal()
    }
}

enum UpdateFailure: Error, Equatable {
    case checkFailed
    case assetsMissing(AppVersion)
    case downloadFailed
    case invalidPackage
    case needsNewerSystem(String)
    case installFailed
    case ineligible(String)

    var title: String {
        switch self {
        case .checkFailed:
            return L.t("Không kiểm tra được cập nhật", "Couldn't check for updates")
        case .assetsMissing(let v):
            return L.t("Plume \(v) chưa sẵn sàng", "Plume \(v) isn't ready yet")
        case .downloadFailed:
            return L.t("Không tải được bản cập nhật", "Couldn't download the update")
        case .invalidPackage:
            return L.t("Gói cập nhật không hợp lệ", "The update package failed verification")
        case .needsNewerSystem:
            return L.t("Cần macOS mới hơn", "A newer macOS is required")
        case .installFailed, .ineligible:
            return L.t("Không thể tự cập nhật", "Plume can't update itself")
        }
    }

    var detail: String {
        switch self {
        case .checkFailed, .downloadFailed:
            return L.t("Kiểm tra kết nối mạng rồi thử lại.", "Check your connection and try again.")
        case .assetsMissing:
            return L.t("Bản phát hành chưa có gói cập nhật. Thử lại sau ít phút.",
                       "The release has no update package yet. Try again in a few minutes.")
        case .invalidPackage:
            return L.t("Plume đã huỷ cài đặt và giữ nguyên bản hiện tại.",
                       "Plume cancelled the install and kept the current version.")
        case .needsNewerSystem(let v):
            return L.t("Bản mới cần macOS \(v) trở lên.", "The new version needs macOS \(v) or later.")
        case .installFailed:
            return L.t("Không thay được ứng dụng. Bản hiện tại vẫn nguyên vẹn; hãy tải bản mới về cài tay.",
                       "The app could not be replaced. The current version is intact; download the new one and install it by hand.")
        case .ineligible(let detail):
            return detail
        }
    }
}

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
