import Foundation

/// `https://ota.htl-8.com/plume/stable/latest.json`, written by
/// `htl-ota publish` (htl-ota docs/OTA.md). It is fetched over https but not
/// trusted for that: `ed25519` signs every byte of the zip with the key in
/// `UpdateKeys`, and the unpacked app must carry Plume's Developer ID.
public struct OTAManifest: Decodable, Equatable {
    public struct Attachment: Decodable, Equatable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let size: Int
    }

    public let app: String
    public let channel: String
    public let version: String
    public let build: Int
    public let url: URL
    public let sha256: String
    public let size: Int
    public let notes: String?
    public let minOs: String?
    public let ed25519: String?
    public let attachments: [Attachment]?
}

/// What the updater checks a download against. Built from `OTAManifest`;
/// still decodable because `Plume-X.Y.manifest.json` (the GitHub-era manifest
/// Scripts/release.sh keeps writing for the bridge release) has this shape.
/// Only `ed25519` is a trust anchor; `length` and `sha256` tell a broken
/// download apart from a forged one.
public struct UpdateManifest: Decodable, Equatable {
    public let format: Int
    public let version: String
    public let build: Int?
    public let minimumSystemVersion: String
    public let asset: String
    public let length: Int
    public let sha256: String
    public let ed25519: String

    public init(format: Int, version: String, build: Int?,
                minimumSystemVersion: String, asset: String,
                length: Int, sha256: String, ed25519: String) {
        self.format = format
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.asset = asset
        self.length = length
        self.sha256 = sha256
        self.ed25519 = ed25519
    }
}

public struct UpdateCandidate: Equatable {
    public let version: AppVersion
    public let title: String
    public let notes: String
    /// The release's `Plume-X.Y.dmg`, for installing by hand when the update
    /// fails; nil when the release has none.
    public let pageURL: URL?
    public let zipURL: URL
    public let zipSize: Int
}

public enum UpdateDecision: Equatable {
    case upToDate
    case skipped(AppVersion)
    /// Newer, but this Mac's macOS is below the release's `minOs`: a release
    /// this Mac cannot run is never offered.
    case unsupported(AppVersion, minimum: String)
    /// Newer, but the manifest does not describe a Plume release we could
    /// verify (wrong asset name, build, missing signature or floor...).
    case invalid(AppVersion)
    /// Not a Plume `latest.json` at all.
    case malformed
    case available(UpdateCandidate, UpdateManifest)
}

public enum UpdateFeed {
    public static let app = "plume"
    public static let channel = "stable"
    public static let feedURL = URL(string: "https://ota.htl-8.com/\(app)/\(channel)/latest.json")!

    public static func assetNames(for version: AppVersion) -> (zip: String, manifest: String, dmg: String) {
        ("Plume-\(version).zip", "Plume-\(version).manifest.json", "Plume-\(version).dmg")
    }

    /// What to do with a 200 answer from `feedURL`. `honourSkip` is false for
    /// a check the user asked for: "Skip This Version" only silences
    /// automatic ones.
    public static func decide(data: Data, current: AppVersion, skipped: AppVersion?,
                              honourSkip: Bool, running: OperatingSystemVersion) -> UpdateDecision {
        guard data.count <= 64 * 1024,
              let feed = try? JSONDecoder().decode(OTAManifest.self, from: data),
              feed.app == app, feed.channel == channel,
              let version = AppVersion(feed.version)
        else { return .malformed }
        guard version > current else { return .upToDate }
        if honourSkip, let skipped, skipped == version { return .skipped(version) }

        let names = assetNames(for: version)
        // `build` is what other clients compare; for Plume it is derived from
        // the version (build_app.sh), so a mismatch means a broken publish.
        guard feed.build == version.build,
              feed.url.scheme == "https", feed.url.lastPathComponent == names.zip,
              feed.sha256.count == 64,
              feed.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              let signature = feed.ed25519, !signature.isEmpty,
              let minimum = feed.minOs, !minimum.isEmpty
        else { return .invalid(version) }
        let manifest = UpdateManifest(
            format: 1, version: feed.version, build: feed.build,
            minimumSystemVersion: minimum, asset: names.zip, length: feed.size,
            sha256: feed.sha256, ed25519: signature)
        guard (try? UpdateVerifier.checkManifest(manifest, expectedVersion: version,
                                                 assetName: names.zip,
                                                 assetSize: feed.size)) != nil,
              feed.size > 0
        else { return .invalid(version) }
        guard SystemVersion.satisfies(minimum: minimum, running: running) else {
            return .unsupported(version, minimum: minimum)
        }
        // By exact name, never by position: a release may carry other files.
        let dmg = feed.attachments?.first { $0.name == names.dmg && $0.url.scheme == "https" }
        return .available(UpdateCandidate(
            version: version,
            title: "Plume \(version)",
            notes: trimNotes(feed.notes),
            pageURL: dmg?.url,
            zipURL: feed.url,
            zipSize: feed.size), manifest)
    }

    /// Release notes for an alert: no carriage returns, at most `limit`
    /// characters, so a long changelog cannot push the buttons off screen.
    public static func trimNotes(_ body: String?, limit: Int = 1200) -> String {
        let text = (body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600

    /// At most one automatic check a day. A last-check time in the future
    /// (the clock was set back) counts as due, or checks would stop for good.
    public static func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= interval
    }

    /// After a check that never reached a verdict (offline, 5xx, rate
    /// limited), how long to wait before the next automatic attempt. Only a
    /// verdict starts the daily interval; this keeps a failure from costing a
    /// whole day without retrying on every app activation either. Rate-limit
    /// headers (Retry-After, X-RateLimit-Reset) are honoured, clamped to between a minute and six
    /// hours so a bad header can neither spin nor silence the updater.
    public static func retryDelay(retryAfter: String?, rateLimitReset: String?,
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

public enum SystemVersion {
    /// "14", "14.0" or "15.1.2".
    public static func parse(_ text: String) -> OperatingSystemVersion? {
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
    public static func satisfies(minimum: String, running: OperatingSystemVersion) -> Bool {
        guard let min = parse(minimum) else { return false }
        return (running.majorVersion, running.minorVersion, running.patchVersion)
            >= (min.majorVersion, min.minorVersion, min.patchVersion)
    }
}
