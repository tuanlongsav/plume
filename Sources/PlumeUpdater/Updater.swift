import AppKit
import PlumeCore
import PlumeUI
import Security
import UserNotifications

/// Self-update from ota.htl-8.com (htl-ota), without Sparkle.
///
/// Trust is the same as Sparkle's: the zip must carry an Ed25519 signature by
/// the key in `UpdateKeys`, and the unpacked app must be signed by Plume's
/// Developer ID team; the server is trusted for neither. The requests are one
/// small `latest.json` (it carries the signature and the minimum macOS, so a
/// release this Mac cannot run is never offered), plus the download when the
/// user says Update: no cookies and nothing but a User-Agent, once a day.
///
/// No timers: one delayed check after launch, then `checkIfDue` on app
/// activation, which is a date comparison until a day has passed (rule 7).
public final class Updater: NSObject, URLSessionDownloadDelegate {
    public static let shared = Updater()

    public typealias Eligibility = UpdateEligibility

    public static var bundleID: String { UpdateInstaller.bundleID }
    public static var requirementText: String { UpdateInstaller.requirementText }
    public static func makeRequirement() -> SecRequirement? { UpdateInstaller.makeRequirement() }
    public static func eligibility() -> Eligibility { UpdateInstaller.eligibility() }

    private static let launchDelay: TimeInterval = 20

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        // `<app>/<version> (<build>)`: the server logs it, which is how we
        // tell which Macs have moved off an old release.
        let current = AppVersion.current
        let version = current?.description ?? "dev"
        let build = current.map { String($0.build) } ?? "0"
        config.httpAdditionalHeaders = ["User-Agent": "\(UpdateFeed.app)/\(version) (\(build))"]
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Set once the launch delay has passed; activation checks wait for it so
    /// the first launch does not hit the network while the page is loading.
    private var armed = false
    /// A check, download or install is under way.
    private var busy = false
    /// Check for Updates… was chosen during an automatic check, which then
    /// answers as a manual one would instead of ending in silence.
    private var manualAnswerWanted = false
    private var job: (candidate: UpdateCandidate, manifest: UpdateManifest)?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadedZip: URL?
    private var progress: UpdateProgressWindow?
    /// No automatic check before this; set after a check that got no verdict.
    /// In memory only: a relaunch may try again at once.
    private var retryNotBefore: Date?

    // MARK: Entry points

    public func scheduleLaunchCheck() {
        UpdateInstaller.removeLeftoverStaging()
        showPostUpdateNoticeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.armed = true
            self?.checkIfDue()
        }
    }

    /// Automatic check: silent unless there is something to offer.
    public func checkIfDue() {
        guard armed, !busy, Preferences.autoUpdateCheck,
              UpdateSchedule.isDue(last: Preferences.lastUpdateCheck),
              retryNotBefore.map({ Date() >= $0 }) ?? true,
              Self.eligibility() == .ok
        else { return }
        check(manual: false)
    }

    /// Plume ▸ Check for Updates…: always answers, ignores "Skip This Version".
    @objc public func checkNow(_ sender: Any?) {
        if busy {
            // A download or install has its window; a check has nothing on
            // screen yet.
            if let progress { progress.bringToFront() } else { manualAnswerWanted = true }
            return
        }
        let eligibility = Self.eligibility()
        guard eligibility == .ok else { explainIneligible(eligibility); return }
        check(manual: true)
    }

    // MARK: Check

    private func check(manual: Bool) {
        guard let current = AppVersion.current else { return }
        busy = true
        let request = URLRequest(url: UpdateFeed.feedURL)
        session.dataTask(with: request) { [weak self] data, response, error in
            Self.onRunLoop { self?.handleCheck(data: data, response: response, error: error,
                                               current: current, manual: manual) }
        }.resume()
    }

    private func handleCheck(data: Data?, response: URLResponse?, error: Error?,
                             current: AppVersion, manual: Bool) {
        busy = false
        let manual = claimManualAnswer(manual)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // Only a verdict starts the daily interval (`markChecked`); anything
        // else retries later the same day instead of waiting until tomorrow.
        if error == nil, status == 200 || status == 404 {
            retryNotBefore = nil
        } else {
            retryNotBefore = Date().addingTimeInterval(UpdateSchedule.retryDelay(
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                rateLimitReset: http?.value(forHTTPHeaderField: "X-RateLimit-Reset")))
        }
        // 404: nothing published on this channel yet.
        if status == 404 {
            markChecked()
            if manual { showUpToDate(current) }
            return
        }
        if status == 403 || status == 429 {
            if manual { showFailure(.rateLimited) }
            return
        }
        guard error == nil, status == 200, let data else {
            if manual { showFailure(.checkFailed) }
            return
        }
        let skipped = Preferences.skippedVersion.flatMap(AppVersion.init)
        let decision = UpdateFeed.decide(
            data: data, current: current, skipped: skipped, honourSkip: !manual,
            running: ProcessInfo.processInfo.operatingSystemVersion)
        // Every case below is a verdict: the server answered.
        markChecked()
        switch decision {
        case .upToDate:
            if manual { showUpToDate(current) }
        case .skipped:
            break
        case .malformed:
            PlumeTrace.log("update: latest.json not understood")
            if manual { showFailure(.checkFailed) }
        case .invalid(let version):
            PlumeTrace.log("update: manifest rejected for \(version)")
            if manual { showFailure(.invalidPackage) }
        case .unsupported(let version, let minimum):
            // Nothing to offer this Mac; an automatic check stays quiet.
            if manual { showLatestNeedsNewerSystem(current, newer: version, needs: minimum) }
        case .available(let candidate, let manifest):
            offer(candidate, manifest: manifest, current: current, manual: manual)
        }
    }

    /// Folds a Check for Updates… chosen while this check was in flight into it.
    private func claimManualAnswer(_ manual: Bool) -> Bool {
        defer { manualAnswerWanted = false }
        return manual || manualAnswerWanted
    }

    /// A check reached a verdict: the next automatic one is due in a day.
    private func markChecked() {
        Preferences.lastUpdateCheck = Date()
        retryNotBefore = nil
    }

    /// URLSession calls back inside a main-queue block. A modal alert run
    /// there would hold the main queue for as long as it is open, stalling
    /// every `DispatchQueue.main` callback in the app; a run-loop block does not.
    private static func onRunLoop(_ work: @escaping () -> Void) {
        RunLoop.main.perform(work)
    }

    private func offer(_ candidate: UpdateCandidate, manifest: UpdateManifest,
                       current: AppVersion, manual: Bool) {
        let installed = L.t("Bạn đang dùng Plume \(current).", "You have Plume \(current).")
        var buttons = [L.t("Cập nhật", "Update"), L.t("Để sau", "Later")]
        if !manual { buttons.append(L.t("Bỏ qua phiên bản này", "Skip This Version")) }
        switch AlertPresenter.presentModal(
            title: L.t("Có bản \(candidate.title)", "\(candidate.title) is available"),
            detail: candidate.notes.isEmpty ? installed : candidate.notes + "\n\n" + installed,
            buttons: buttons,
            userInitiated: manual
        ) {
        case .alertFirstButtonReturn:
            Preferences.skippedVersion = nil
            busy = true
            startDownload(candidate, manifest: manifest)
        case .alertThirdButtonReturn:
            Preferences.skippedVersion = candidate.version.description
        default:
            break
        }
    }

    // MARK: Download

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

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard downloadTask === self.downloadTask, let job else { return }
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite : Int64(job.manifest.length)
        progress?.setFraction(Double(totalBytesWritten) / Double(max(total, 1)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
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

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
        let staging = UpdateInstaller.stagingURL
        // Hashing, unzipping and the signature check take a few seconds on a
        // universal binary; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, UpdateFailure>
            do {
                guard let key = UpdateKeys.publicKey else { throw UpdateFailure.invalidPackage }
                let data = try Data(contentsOf: zip, options: .mappedIfSafe)
                try UpdateVerifier.verifyArchive(data, manifest: manifest, publicKey: key)
                let app = try UpdateInstaller.unpack(zip, into: staging)
                try UpdateInstaller.verifyBundle(app, expected: candidate.version)
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

    /// Swap the verified app into place in one atomic rename, so there is
    /// never a moment with no Plume.app; then quit and let a detached shell
    /// reopen it. The running binary keeps working after its bundle moves.
    private func swapAndRelaunch(staged: URL, installed: URL, staging: URL,
                                 version: AppVersion, page: URL?) {
        do {
            try UpdateInstaller.swap(staged, into: installed)
        } catch {
            PlumeTrace.log("update: swap failed: \(error)")
            try? FileManager.default.removeItem(at: staging)
            finishWithFailure(.installFailed, page: page)
            return
        }
        Preferences.pendingUpdateNotice = version.description
        do {
            try UpdateInstaller.launchRelaunchHelper(staging: staging, installed: installed)
        } catch {
            // Installed but not relaunched: say so rather than quit silently.
            finishQuietly()
            AlertPresenter.presentModal(
                title: L.t("Đã cài Plume \(version)", "Plume \(version) is installed"),
                detail: L.t("Thoát và mở lại Plume để dùng bản mới.", "Quit and reopen Plume to use it.")
            )
            return
        }
        progress?.close()
        progress = nil
        NSApp.terminate(nil)
    }

    // MARK: Housekeeping

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

    /// `page` is the release's DMG, for installing by hand. A Mac too old for
    /// this release gets no link: the DMG would not run there either.
    private func showFailure(_ failure: UpdateFailure, page: URL? = nil) {
        var target = page
        if case .needsNewerSystem = failure { target = nil }
        let buttons = target == nil ? [] : ["OK", L.t("Mở trang tải về", "Open Download Page")]
        if AlertPresenter.presentModal(title: failure.title, detail: failure.detail,
                                       buttons: buttons, style: .warning)
            == .alertSecondButtonReturn, let target {
            NSWorkspace.shared.open(target)
        }
    }

    /// Only the latest release is read, so a version between it and this one
    /// that still runs here is unknown (a Mac that missed the last release
    /// for its macOS): never claim this is the newest for this Mac.
    private func showLatestNeedsNewerSystem(_ current: AppVersion, newer: AppVersion,
                                            needs minimum: String) {
        AlertPresenter.presentModal(
            title: L.t("Plume \(newer) cần macOS \(minimum) trở lên",
                       "Plume \(newer) needs macOS \(minimum) or later"),
            detail: L.t("Máy này đang dùng Plume \(current).", "This Mac has Plume \(current).")
        )
    }

    private func showUpToDate(_ current: AppVersion) {
        AlertPresenter.presentModal(
            title: L.t("Bạn đang dùng bản mới nhất", "You're up to date"),
            detail: L.t("Plume \(current) là phiên bản mới nhất.", "Plume \(current) is the newest version.")
        )
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
}
