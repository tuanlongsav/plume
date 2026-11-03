import XCTest
@testable import Plume

final class UpdateFeedTests: XCTestCase {

    /// The shape of `GET /repos/{owner}/{repo}/releases/latest`, trimmed to
    /// what matters plus a few fields the decoder must ignore.
    private func releaseJSON(tag: String = "v1.2", prerelease: Bool = false, draft: Bool = false,
                             assets: [String] = ["Plume-1.2.dmg", "Plume-1.2.zip",
                                                 "Plume-1.2.manifest.json"]) -> Data {
        let list = assets.enumerated().map { i, name in
            """
            {"id": \(i), "name": "\(name)", "size": \(1000 + i),
             "content_type": "application/zip",
             "browser_download_url": "https://github.com/tuanlongsav/plume/releases/download/\(tag)/\(name)"}
            """
        }.joined(separator: ",")
        return Data("""
        {"url": "https://api.github.com/x", "id": 1, "tag_name": "\(tag)",
         "name": "Plume 1.2", "body": "- Faster\\r\\n- Smaller",
         "draft": \(draft), "prerelease": \(prerelease),
         "html_url": "https://github.com/tuanlongsav/plume/releases/tag/\(tag)",
         "published_at": "2026-11-03T00:00:00Z", "assets": [\(list)]}
        """.utf8)
    }

    private func release(_ data: Data) throws -> UpdateRelease {
        try JSONDecoder().decode(UpdateRelease.self, from: data)
    }

    private let v11 = AppVersion("1.1")!

    func testDecodesTheFieldsItNeeds() throws {
        let r = try release(releaseJSON())
        XCTAssertEqual(r.tagName, "v1.2")
        XCTAssertEqual(r.name, "Plume 1.2")
        XCTAssertFalse(r.prerelease)
        XCTAssertEqual(r.assets.count, 3)
        XCTAssertEqual(r.assets[1].browserDownloadURL.lastPathComponent, "Plume-1.2.zip")
        XCTAssertEqual(r.assets[1].size, 1001)
    }

    func testOffersANewerRelease() throws {
        let decision = UpdateFeed.decide(release: try release(releaseJSON()), current: v11,
                                         skipped: nil, honourSkip: true)
        guard case .available(let c) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(c.version, AppVersion("1.2"))
        XCTAssertEqual(c.title, "Plume 1.2")
        XCTAssertEqual(c.notes, "- Faster\n- Smaller")
        XCTAssertEqual(c.zipURL.lastPathComponent, "Plume-1.2.zip")
        XCTAssertEqual(c.zipSize, 1001)
        XCTAssertEqual(c.manifestURL.lastPathComponent, "Plume-1.2.manifest.json")
    }

    func testSameOrOlderIsUpToDate() throws {
        let r = try release(releaseJSON())
        for current in ["1.2", "1.2.0", "1.3", "2.0"] {
            XCTAssertEqual(UpdateFeed.decide(release: r, current: AppVersion(current)!,
                                             skipped: nil, honourSkip: true), .upToDate, current)
        }
    }

    func testIgnoresPrereleasesDraftsAndOddTags() throws {
        for data in [releaseJSON(prerelease: true), releaseJSON(draft: true),
                     releaseJSON(tag: "nightly"), releaseJSON(tag: "v1.2-beta")] {
            XCTAssertEqual(UpdateFeed.decide(release: try release(data), current: v11,
                                             skipped: nil, honourSkip: true), .upToDate)
        }
    }

    func testSkippedVersionSilencesOnlyAutomaticChecks() throws {
        let r = try release(releaseJSON())
        let skipped = AppVersion("1.2")
        XCTAssertEqual(UpdateFeed.decide(release: r, current: v11, skipped: skipped, honourSkip: true),
                       .skipped(AppVersion("1.2")!))
        guard case .available = UpdateFeed.decide(release: r, current: v11,
                                                  skipped: skipped, honourSkip: false)
        else { return XCTFail("a manual check must ignore the skip") }
        // Skipping 1.1 says nothing about 1.2.
        guard case .available = UpdateFeed.decide(release: r, current: AppVersion("1.0")!,
                                                  skipped: v11, honourSkip: true)
        else { return XCTFail("an older skip must not hide a newer release") }
    }

    func testAssetsAreMatchedByExactName() throws {
        for assets in [["Plume-1.2.dmg", "Plume-1.2.zip"],
                       ["Plume-1.2.dmg", "Plume-1.2.manifest.json"],
                       ["Plume-1.2-beta.zip", "Plume-1.2.manifest.json"],
                       ["plume-1.2.zip", "Plume-1.2.manifest.json"]] {
            let decision = UpdateFeed.decide(release: try release(releaseJSON(assets: assets)),
                                             current: v11, skipped: nil, honourSkip: true)
            guard case .assetsMissing(let v, _) = decision else { return XCTFail("\(assets)") }
            XCTAssertEqual(v, AppVersion("1.2"))
        }
        // Order and extra files do not matter.
        let shuffled = ["Plume-1.2.manifest.json", "notes.txt", "Plume-1.2.zip"]
        guard case .available = UpdateFeed.decide(release: try release(releaseJSON(assets: shuffled)),
                                                  current: v11, skipped: nil, honourSkip: true)
        else { return XCTFail("shuffled assets") }
    }

    func testAssetNames() {
        let names = UpdateFeed.assetNames(for: AppVersion("v1.10")!)
        XCTAssertEqual(names.zip, "Plume-1.10.zip")
        XCTAssertEqual(names.manifest, "Plume-1.10.manifest.json")
    }

    func testRepoOverrideIsValidated() {
        XCTAssertEqual(UpdateFeed.latestReleaseURL(repo: "tuanlongsav/plume")?.absoluteString,
                       "https://api.github.com/repos/tuanlongsav/plume/releases/latest")
        for bad in ["", "plume", "a/b/c", "../x", "a/..", "a b/c", "a/b?x=1", "évil/x"] {
            XCTAssertNil(UpdateFeed.latestReleaseURL(repo: bad), bad)
        }
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
}
