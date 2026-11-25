import CryptoKit
import XCTest
@testable import PlumeUpdater

final class UpdateFeedTests: XCTestCase {

    private static let sha = String(repeating: "ab", count: 32)

    /// `https://ota.htl-8.com/plume/stable/latest.json` as `htl-ota publish`
    /// writes it (htl-ota docs/OTA.md), plus a field the decoder must ignore.
    private func feedJSON(app: String = "plume", channel: String = "stable",
                          version: String = "1.2", build: Int = 10200,
                          url: String = "https://ota.htl-8.com/plume/10200/Plume-1.2.zip",
                          sha256: String = UpdateFeedTests.sha, size: Int = 1001,
                          minOs: String? = "13.3", ed25519: String? = "c2ln",
                          notes: String = "- Faster\\r\\n- Smaller",
                          attachments: String = """
                          [{"name": "Plume-1.2.dmg", "url": "https://ota.htl-8.com/plume/10200/Plume-1.2.dmg",
                            "sha256": "\(UpdateFeedTests.sha)", "size": 2002}]
                          """) -> Data {
        var fields = [
            "\"app\": \"\(app)\"", "\"channel\": \"\(channel)\"",
            "\"version\": \"\(version)\"", "\"build\": \(build)", "\"url\": \"\(url)\"",
            "\"sha256\": \"\(sha256)\"", "\"size\": \(size)", "\"notes\": \"\(notes)\"",
            "\"publishedAt\": \"2026-11-22T06:00:00.000Z\"", "\"attachments\": \(attachments)",
            "\"extra\": true",
        ]
        if let minOs { fields.append("\"minOs\": \"\(minOs)\"") }
        if let ed25519 { fields.append("\"ed25519\": \"\(ed25519)\"") }
        return Data(("{" + fields.joined(separator: ", ") + "}").utf8)
    }

    private let v11 = AppVersion("1.1")!
    private let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)

    private func decide(_ data: Data, current: AppVersion? = nil, skipped: AppVersion? = nil,
                        honourSkip: Bool = true) -> UpdateDecision {
        UpdateFeed.decide(data: data, current: current ?? v11, skipped: skipped,
                          honourSkip: honourSkip, running: ventura)
    }

    func testFeedURL() {
        XCTAssertEqual(UpdateFeed.feedURL.absoluteString,
                       "https://ota.htl-8.com/plume/stable/latest.json")
    }

    func testOffersANewerRelease() throws {
        guard case .available(let c, let m) = decide(feedJSON()) else {
            return XCTFail("\(decide(feedJSON()))")
        }
        XCTAssertEqual(c.version, AppVersion("1.2"))
        XCTAssertEqual(c.title, "Plume 1.2")
        XCTAssertEqual(c.notes, "- Faster\n- Smaller")
        XCTAssertEqual(c.zipURL.absoluteString, "https://ota.htl-8.com/plume/10200/Plume-1.2.zip")
        XCTAssertEqual(c.zipSize, 1001)
        XCTAssertEqual(c.pageURL?.lastPathComponent, "Plume-1.2.dmg")
        // Mapped onto what UpdateVerifier checks the download against.
        XCTAssertEqual(m, UpdateManifest(format: 1, version: "1.2", build: 10200,
                                         minimumSystemVersion: "13.3", asset: "Plume-1.2.zip",
                                         length: 1001, sha256: Self.sha, ed25519: "c2ln"))
    }

    func testSameOrOlderIsUpToDate() {
        for current in ["1.2", "1.2.0", "1.3", "2.0"] {
            XCTAssertEqual(decide(feedJSON(), current: AppVersion(current)!), .upToDate, current)
        }
    }

    func testSkippedVersionSilencesOnlyAutomaticChecks() {
        let skipped = AppVersion("1.2")
        XCTAssertEqual(decide(feedJSON(), skipped: skipped), .skipped(AppVersion("1.2")!))
        guard case .available = decide(feedJSON(), skipped: skipped, honourSkip: false)
        else { return XCTFail("a manual check must ignore the skip") }
        // Skipping 1.1 says nothing about 1.2.
        guard case .available = decide(feedJSON(), current: AppVersion("1.0")!, skipped: v11)
        else { return XCTFail("an older skip must not hide a newer release") }
    }

    // Another app's or channel's manifest, or no manifest at all.
    func testForeignOrBrokenFeedIsMalformed() {
        XCTAssertEqual(decide(feedJSON(app: "rowa")), .malformed)
        XCTAssertEqual(decide(feedJSON(channel: "beta")), .malformed)
        XCTAssertEqual(decide(feedJSON(version: "1.2-beta")), .malformed)
        XCTAssertEqual(decide(Data("not json".utf8)), .malformed)
        XCTAssertEqual(decide(Data(count: 70 * 1024)), .malformed)
    }

    func testManifestThatDoesNotDescribeTheReleaseIsInvalid() {
        let v12 = AppVersion("1.2")!
        let bad: [Data] = [
            feedJSON(build: 10300),
            feedJSON(url: "http://ota.htl-8.com/plume/10200/Plume-1.2.zip"),
            feedJSON(url: "https://ota.htl-8.com/plume/10200/Plume-1.3.zip"),
            feedJSON(url: "https://ota.htl-8.com/plume/10200/plume-1.2.zip"),
            feedJSON(sha256: "AB" + String(Self.sha.dropFirst(2))),
            feedJSON(sha256: "ab"),
            feedJSON(size: 0),
            feedJSON(minOs: nil),
            feedJSON(ed25519: nil),
            feedJSON(ed25519: ""),
        ]
        for data in bad {
            XCTAssertEqual(decide(data), .invalid(v12), String(decoding: data, as: UTF8.self))
        }
    }

    // A release this Mac cannot run is never offered.
    func testReleaseNeedingANewerMacIsNotOffered() {
        let v12 = AppVersion("1.2")!
        XCTAssertEqual(decide(feedJSON(minOs: "14.0")), .unsupported(v12, minimum: "14.0"))
        XCTAssertEqual(decide(feedJSON(minOs: "13.7")), .unsupported(v12, minimum: "13.7"))
    }

    // The DMG link is matched by exact name and https; its absence is no reason
    // to withhold the update.
    func testDMGLinkIsOptional() {
        for attachments in ["[]",
                            "[{\"name\": \"Plume-1.2.dmg\", \"url\": \"http://x/Plume-1.2.dmg\", \"sha256\": \"a\", \"size\": 1}]",
                            "[{\"name\": \"Plume-1.3.dmg\", \"url\": \"https://x/Plume-1.3.dmg\", \"sha256\": \"a\", \"size\": 1}]"] {
            guard case .available(let c, _) = decide(feedJSON(attachments: attachments))
            else { return XCTFail(attachments) }
            XCTAssertNil(c.pageURL, attachments)
        }
    }

    // What htl-ota publish writes is what the download is verified against:
    // a signature over the zip by the trusted key, nothing from the server.
    func testSignedFeedVerifiesTheDownload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let zip = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let sig = try key.signature(for: zip).base64EncodedString()
        let data = feedJSON(sha256: sha, size: zip.count, ed25519: sig)
        guard case .available(_, let manifest) = decide(data) else { return XCTFail() }
        XCTAssertNoThrow(try UpdateVerifier.verifyArchive(zip, manifest: manifest,
                                                          publicKey: key.publicKey))
        var forged = zip
        forged[0] ^= 1
        XCTAssertThrowsError(try UpdateVerifier.verifyArchive(forged, manifest: manifest,
                                                              publicKey: key.publicKey))
        XCTAssertThrowsError(try UpdateVerifier.verifyArchive(
            zip, manifest: manifest, publicKey: Curve25519.Signing.PrivateKey().publicKey))
    }

    func testAssetNames() {
        let names = UpdateFeed.assetNames(for: AppVersion("v1.10")!)
        XCTAssertEqual(names.zip, "Plume-1.10.zip")
        XCTAssertEqual(names.manifest, "Plume-1.10.manifest.json")
        XCTAssertEqual(names.dmg, "Plume-1.10.dmg")
    }

    func testTrimNotes() {
        XCTAssertEqual(UpdateFeed.trimNotes(nil), "")
        XCTAssertEqual(UpdateFeed.trimNotes("  a\r\nb\rc  "), "a\nb\nc")
        let long = String(repeating: "x", count: 2000)
        let trimmed = UpdateFeed.trimNotes(long, limit: 100)
        XCTAssertEqual(trimmed.count, 101)
        XCTAssertTrue(trimmed.hasSuffix("…"))
    }

    func testCheckIsDueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateSchedule.isDue(last: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(last: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
        // Clock set back: a "last check" in the future must not stop checks forever.
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(3600), now: now))
    }

    func testMinimumSystemVersion() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        XCTAssertTrue(SystemVersion.satisfies(minimum: "14.0", running: sonoma))
        XCTAssertTrue(SystemVersion.satisfies(minimum: "14", running: sonoma))
        XCTAssertTrue(SystemVersion.satisfies(minimum: "14.6.1", running: sonoma))
        XCTAssertFalse(SystemVersion.satisfies(minimum: "14.7", running: sonoma))
        XCTAssertFalse(SystemVersion.satisfies(minimum: "15", running: sonoma))
        XCTAssertFalse(SystemVersion.satisfies(minimum: "x", running: sonoma))
        XCTAssertFalse(SystemVersion.satisfies(minimum: "", running: sonoma))
    }

    func testCheckIsDueAtExactlyADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(-24 * 3600), now: now))
    }

    // A failed check retries within the day, on the server's terms when it gives any.
    func testRetryDelayAfterAFailedCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: nil, rateLimitReset: nil, now: now), 3600)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: "120", rateLimitReset: nil, now: now), 120)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: nil, rateLimitReset: "1800000900", now: now), 900)
        // Retry-After wins over the reset time.
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: "300", rateLimitReset: "1800000900", now: now), 300)
        // Clamped: never a tight loop, never silent for more than six hours.
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: "0", rateLimitReset: nil, now: now), 60)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: nil, rateLimitReset: "1700000000", now: now), 60)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: "999999", rateLimitReset: nil, now: now), 6 * 3600)
        XCTAssertEqual(UpdateSchedule.retryDelay(retryAfter: "soon", rateLimitReset: nil, now: now), 3600)
    }
}
