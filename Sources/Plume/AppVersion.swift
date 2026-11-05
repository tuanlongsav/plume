import Foundation

/// A Plume version as Scripts/release.sh stamps and tags it: `MAJOR.MINOR`,
/// tagged `vMAJOR.MINOR`. A third component is accepted so older strings such
/// as `0.1.0` still parse; missing components compare as zero, so `1.2` and
/// `1.2.0` are the same version.
struct AppVersion: Comparable, Hashable, CustomStringConvertible {
    let components: [Int]

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            // ASCII digits only: `isNumber` alone also accepts other scripts'
            // numerals and fractions, which `Int(_:)` then rejects anyway.
            guard !part.isEmpty, part.count <= 6,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            values.append(value)
        }
        // `build` packs MINOR into two digits (as build_app.sh does), so a
        // larger one would collide with the next MAJOR: 1.100 and 2.0 both
        // came out as 20000. The release scripts refuse it; so does this.
        guard values.dropFirst().allSatisfy({ $0 <= 99 }) else { return nil }
        components = values
    }

    var major: Int { components[0] }
    var minor: Int { components[1] }
    private var patch: Int { components.count > 2 ? components[2] : 0 }

    /// `0.0.0`: a local build (build_app.sh's default). Never auto-updated.
    var isDev: Bool { components.allSatisfy { $0 == 0 } }

    /// `CFBundleVersion` for this version, as build_app.sh derives it.
    var build: Int { isDev ? 1 : major * 10000 + minor * 100 }

    var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    var tag: String { "v" + description }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// The running app's `CFBundleShortVersionString`.
    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init)
    }
}
