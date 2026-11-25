import Foundation
import Security

public enum UpdateEligibility: Equatable {
    case ok, devBuild, noPublicKey, notDeveloperID
    case translocated, readOnlyVolume, notWritable
}

/// Local system side of self-updating: Developer ID eligibility, archive
/// unpacking (`ditto`), code-signature verification, atomic bundle swap and
/// detached relaunch. Separated from `Updater`'s network/UI state machine.
public enum UpdateInstaller {
    public static let bundleID = "com.htl.plume"

    /// Plume's Developer ID: Apple-anchored, a Developer ID leaf (the two
    /// OIDs), team U4B264GM2B. `codesign --verify` alone would also accept an
    /// ad-hoc signature, which proves nothing about who built the app.
    public static let requirementText =
        "anchor apple generic and identifier \"\(bundleID)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"U4B264GM2B\""

    /// Next to the app, so the final swap is a rename on one volume.
    public static var stagingURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".Plume-update", isDirectory: true)
    }

    // MARK: Eligibility & Code Signature

    public static func eligibility() -> UpdateEligibility {
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

    public static func makeRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: Unpack, Verify & Swap

    /// `ditto` is what made the zip; it restores the bundle's symlinks and
    /// extended attributes exactly. Only ever run on an archive whose
    /// signature has already been verified.
    public static func unpack(_ zip: URL, into staging: URL) throws -> URL {
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
    public static func verifyBundle(_ app: URL, expected: AppVersion) throws {
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

    /// Same algorithm as Scripts/swap_bundle.swift: afterwards `staged` holds
    /// the old app, which the relaunch script deletes.
    public static func swap(_ staged: URL, into installed: URL) throws {
        // errno is read inside the closure: the path conversions on the way
        // out may overwrite it.
        let err: Int32 = staged.withUnsafeFileSystemRepresentation { from in
            installed.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        if err == 0 { return }
        guard err == ENOTSUP || err == EINVAL else { throw UpdateFailure.installFailed }
        // No RENAME_SWAP here (some network volumes): two renames, each
        // atomic, with the old app put back if the second one fails, where
        // replaceItemAt could fail halfway with nothing to roll back.
        //
        // The old app waits BESIDE the installed one, never in the staging
        // dir: a failed install deletes that dir, and if the rollback also
        // failed it would have held the only Plume left.
        let from = staged.path, to = installed.path, old = installed.path + ".old"
        // A leftover from an interrupted earlier fallback would make every
        // later rename onto it fail (ENOTEMPTY). Safe to remove only while an
        // app sits at the installed path: then it is not the last copy.
        let fm = FileManager.default
        if fm.fileExists(atPath: old), fm.fileExists(atPath: to) {
            try? fm.removeItem(atPath: old)
        }
        guard rename(to, old) == 0 else { throw UpdateFailure.installFailed }
        guard rename(from, to) == 0 else {
            _ = rename(old, to)
            throw UpdateFailure.installFailed
        }
        // Installed. Move the old app into the staging dir, which the
        // relaunch script (or the next launch) removes; failing that, now.
        if rename(old, from) != 0 { try? fm.removeItem(atPath: old) }
    }

    /// Spawn a detached shell helper that waits up to a minute for this process
    /// to exit, deletes `staging`, and opens `installed`.
    public static func launchRelaunchHelper(staging: URL, installed: URL) throws {
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
        try shell.run()
    }

    public static func removeLeftoverStaging() {
        try? FileManager.default.removeItem(at: stagingURL)
    }
}
