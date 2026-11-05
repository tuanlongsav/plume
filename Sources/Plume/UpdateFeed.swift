import Foundation

/// The fields of a GitHub release that the updater reads
/// (`GET /repos/{owner}/{repo}/releases/latest`).
struct UpdateRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, prerelease, draft, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// `Plume-X.Y.manifest.json`, written by Scripts/release.sh. Only `ed25519`
/// is a trust anchor: it signs every byte of the zip. `length` and `sha256`
/// tell a broken download apart from a forged one, and `version` is checked
/// against both the release tag and the unpacked bundle.
struct UpdateManifest: Decodable, Equatable {
    let format: Int
    let version: String
    let build: Int?
    let minimumSystemVersion: String
    let asset: String
    let length: Int
    let sha256: String
    let ed25519: String
}

struct UpdateCandidate: Equatable {
    let version: AppVersion
    let title: String
    let notes: String
    let pageURL: URL
    let zipURL: URL
    let zipSize: Int
    let manifestURL: URL
}

enum UpdateDecision: Equatable {
    case upToDate
    case skipped(AppVersion)
    /// Newer, but its zip or manifest is not (yet) attached — e.g. while
    /// `gh release create` is still uploading.
    case assetsMissing(AppVersion, page: URL)
    case available(UpdateCandidate)
}

enum ManifestVerdict: Equatable {
    case offer(UpdateManifest)
    /// The release needs a newer macOS than this Mac runs.
    case unsupported(minimum: String)
    /// It arrived but does not describe the release it is attached to.
    case invalid
    /// No usable answer; worth another try later.
    case unreachable
}

enum UpdateFeed {
    static let defaultRepo = "tuanlongsav/plume"

    /// `owner/name` only. The repo can be overridden in defaults for a dry
    /// run, so it is never spliced into a URL unchecked.
    static func latestReleaseURL(repo: String) -> URL? {
        guard isValidRepo(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    static func releasesPageURL(repo: String) -> URL? {
        guard isValidRepo(repo) else { return nil }
        return URL(string: "https://github.com/\(repo)/releases/latest")
    }

    /// Every release, for a Mac whose macOS the latest one no longer supports:
    /// an older release there may still run.
    static func allReleasesPageURL(repo: String) -> URL? {
        guard isValidRepo(repo) else { return nil }
        return URL(string: "https://github.com/\(repo)/releases")
    }

    /// The candidate's manifest, read before the user is asked, so a release
    /// this Mac cannot run is never offered (it used to be, and was refused
    /// only after Update, then offered again the next day).
    static func judgeManifest(data: Data?, status: Int, failed: Bool,
                              candidate: UpdateCandidate,
                              running: OperatingSystemVersion) -> ManifestVerdict {
        guard !failed, status == 200, let data else { return .unreachable }
        guard data.count <= 64 * 1024,
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
              (try? UpdateVerifier.checkManifest(
                  manifest, expectedVersion: candidate.version,
                  assetName: assetNames(for: candidate.version).zip,
                  assetSize: candidate.zipSize)) != nil
        else { return .invalid }
        guard SystemVersion.satisfies(minimum: manifest.minimumSystemVersion, running: running) else {
            return .unsupported(minimum: manifest.minimumSystemVersion)
        }
        return .offer(manifest)
    }

    private static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
        }
    }

    static func assetNames(for version: AppVersion) -> (zip: String, manifest: String) {
        ("Plume-\(version).zip", "Plume-\(version).manifest.json")
    }

    /// What to do with the latest release. `honourSkip` is false for a check
    /// the user asked for: "Skip This Version" only silences automatic ones.
    static func decide(release: UpdateRelease, current: AppVersion,
                       skipped: AppVersion?, honourSkip: Bool) -> UpdateDecision {
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tagName), version > current
        else { return .upToDate }
        if honourSkip, let skipped, skipped == version { return .skipped(version) }

        // By exact name, never by position: a release may carry other files.
        let names = assetNames(for: version)
        guard let zip = release.assets.first(where: { $0.name == names.zip }),
              let manifest = release.assets.first(where: { $0.name == names.manifest }),
              zip.browserDownloadURL.scheme == "https",
              manifest.browserDownloadURL.scheme == "https"
        else { return .assetsMissing(version, page: release.htmlURL) }

        let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .available(UpdateCandidate(
            version: version,
            title: name.isEmpty ? "Plume \(version)" : name,
            notes: trimNotes(release.body),
            pageURL: release.htmlURL,
            zipURL: zip.browserDownloadURL,
            zipSize: zip.size,
            manifestURL: manifest.browserDownloadURL))
    }

    /// Release notes for an alert: no carriage returns, at most `limit`
    /// characters, so a long changelog cannot push the buttons off screen.
    static func trimNotes(_ body: String?, limit: Int = 1200) -> String {
        let text = (body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum UpdateSchedule {
    static let interval: TimeInterval = 24 * 3600

    /// At most one automatic check a day. A last-check time in the future
    /// (the clock was set back) counts as due, or checks would stop for good.
    static func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= interval
    }

    /// After a check that never reached a verdict (offline, 5xx, rate
    /// limited), how long to wait before the next automatic attempt. Only a
    /// verdict starts the daily interval; this keeps a failure from costing a
    /// whole day without retrying on every app activation either. GitHub's
    /// rate-limit headers are honoured, clamped to between a minute and six
    /// hours so a bad header can neither spin nor silence the updater.
    static func retryDelay(retryAfter: String?, rateLimitReset: String?,
                           now: Date = Date()) -> TimeInterval {
        let fallback: TimeInterval = 3600
        var delay = fallback
        if let s = retryAfter?.trimmingCharacters(in: .whitespaces), let v = TimeInterval(s) {
            delay = v
        } else if let s = rateLimitReset?.trimmingCharacters(in: .whitespaces), let epoch = TimeInterval(s) {
            delay = epoch - now.timeIntervalSince1970
        }
        return min(max(delay, 60), 6 * 3600)
    }
}

enum SystemVersion {
    /// "14", "14.0" or "15.1.2".
    static func parse(_ text: String) -> OperatingSystemVersion? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        return OperatingSystemVersion(majorVersion: values[0], minorVersion: values[1],
                                      patchVersion: values[2])
    }

    /// Unparseable means no: an update that may not launch is not offered.
    static func satisfies(minimum: String, running: OperatingSystemVersion) -> Bool {
        guard let min = parse(minimum) else { return false }
        return (running.majorVersion, running.minorVersion, running.patchVersion)
            >= (min.majorVersion, min.minorVersion, min.patchVersion)
    }
}
