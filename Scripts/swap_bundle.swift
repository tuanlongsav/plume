// Put a freshly built app in place of the installed one in a single rename.
//
//   swift Scripts/swap_bundle.swift <staged.app> <installed.app>
//
// With an app already at <installed.app>, the two are exchanged atomically
// (renamex_np RENAME_SWAP): there is never a moment with no app at that path,
// and afterwards <staged.app> holds the OLD app for the caller to delete.
// With nothing installed yet, <staged.app> is simply renamed into place.
// Both paths must be on the same volume — stage beside the destination.
//
// Shell has no atomic swap on macOS (BSD mv has no --exchange), and an
// `rm -rf old; mv new old` pair leaves no app at all if interrupted between
// the two. The in-app updater swaps the same way (Updater.swap).
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: swift Scripts/swap_bundle.swift <staged.app> <installed.app>") }
let staged = args[1], installed = args[2]
let fm = FileManager.default
guard fm.fileExists(atPath: staged) else { fail("not found: \(staged)") }

if !fm.fileExists(atPath: installed) {
    guard rename(staged, installed) == 0 else {
        fail("rename failed: \(String(cString: strerror(errno)))")
    }
    exit(0)
}

if renamex_np(staged, installed, UInt32(RENAME_SWAP)) == 0 { exit(0) }
let swapError = errno
guard swapError == ENOTSUP || swapError == EINVAL else {
    fail("swap failed: \(String(cString: strerror(swapError)))")
}

// A file system without RENAME_SWAP (some network volumes): two renames, each
// atomic, so an interruption leaves the old app at <staged.app> rather than
// nothing — and the old app is put back if the second rename fails.
guard rename(installed, staged + ".old") == 0 else {
    fail("rename failed: \(String(cString: strerror(errno)))")
}
guard rename(staged, installed) == 0 else {
    let error = String(cString: strerror(errno))
    _ = rename(staged + ".old", installed)
    fail("rename failed: \(error)")
}
guard rename(staged + ".old", staged) == 0 else {
    fail("installed, but the old app is left at \(staged).old")
}
