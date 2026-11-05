# Plume

A lightweight, native macOS client for Facebook Messenger — like
[Caprine](https://github.com/sindresorhus/caprine), but without Electron.

Caprine bundles a full Chromium (~150 MB) per app. Plume wraps
`messenger.com` in the system **WebKit** (`WKWebView`) instead, so the app
is a few MB, starts fast, scrolls with native momentum, and shares the OS's
WebKit security updates. Pure Swift + AppKit — no runtime dependencies.

## Install

Download **Plume-X.Y.dmg** from the
[latest release](https://github.com/tuanlongsav/plume/releases/latest), open
it and drag Plume into Applications. It is signed and notarized, so it opens
without warnings, and later versions install themselves (Plume asks first).

Requires **macOS 13.3 (Ventura) or later**, on Apple silicon or Intel. On
macOS 13.0–13.2, update macOS first (System Settings ▸ Software Update). Plume
uses the WebKit that ships with macOS, not the installed Safari: 13.3 is the
first whose engine Facebook serves Messenger to. A Mac that already runs an
older Plume that cannot update itself installs the new DMG by hand once.

## Features

- Native `WKWebView` shell, persistent login (cookies survive relaunch)
- Real macOS notifications (the web `Notification` API is bridged to
  `UNUserNotificationCenter`); clicking a banner reopens that thread
- Dock unread badge, synced from the page's unread count
- Outbound links open in your default browser, not inside the app
- Calls (and any other window Messenger opens) get a real window of their own
- Native file picker for attachments; camera/mic granted for calls
- In-app PDF viewing for attachments (PDFKit); other files reveal in Finder
- Conversation keyboard shortcuts (⌘1–9 jump, next/previous, next unread, find,
  ⌘N new message)
- Chat bubbles: an Android-style chain of chat heads that floats over every
  Space and full-screen app, with the conversation in a card beside it
- Updates itself from GitHub Releases: checks once a day, asks before
  installing, and only installs archives signed with Plume's update key and
  apps signed with its Developer ID
- Always-on-top window; toolbar & theming toggles
- Optional menu bar icon with the unread count (Plume keeps running there when
  the window is closed) and an optional global shortcut, ⌃⌥⌘M, to bring Plume
  up or put it away from any app
- Page zoom (⌘+ ⌘− ⌘0), remembered
- Remembers window size & position; full-screen, back/forward, reload

Plume deliberately injects almost no CSS into Messenger. Decorative layers we
tried (custom scrollbars, per-bubble shadows, an accent tint) measurably slowed
the page down — see the performance note in
[`InjectedScript.swift`](Sources/Plume/InjectedScript.swift) before adding any.

The conversation-navigation logic is adapted from
[Caprine](https://github.com/sindresorhus/caprine) — MIT © Sindre Sorhus; see
[`NOTICE`](NOTICE).

## Known limitations

After an in-place change to a conversation — e.g. **unsending a message** — the
**conversation list can fail to re-render** its latest-message preview (or drop
the row) until the page is reloaded. This is a **Messenger web bug that shows up
in every browser** (Chrome included), not something a wrapper can fix — Plume
only injects CSS/JS and can't touch Messenger's own render logic. Recovery:
**⌘R** (Reload), or click another conversation and back — no messages are lost.

## Build

```sh
swift test                             # unit tests (needs macOS)
bash Scripts/install.sh                # build release → /Applications/Plume.app, relaunch
bash Scripts/build_app.sh release     # → build/Plume.app
open build/Plume.app

bash Scripts/release.sh 1.0            # sign, notarize and publish a release
```

CI runs `swift test` and a release build on a macOS runner for every pull
request and every push to `main` ([`ci.yml`](.github/workflows/ci.yml)).

Requires Xcode 16 or later (Swift 6 toolchain, macOS 15 SDK); the app itself
runs on macOS 13.3 and later. `build_app.sh` compiles with
SwiftPM, assembles the `.app` bundle with an `Info.plist` and app icon, and
ad-hoc signs it (needed for notifications and camera/mic TCC prompts).
`install.sh` runs that build, quits a running Plume, replaces the copy in
`/Applications` and opens it (it refuses to replace an installed release, which
updates itself; a local build would not) — login and settings carry over, though a new
ad-hoc signature can make macOS ask for camera/mic (and, the first time a
non-PDF attachment is saved to ~/Downloads, Downloads-folder) access again.
`release.sh` (via `release_sign.sh`) builds a universal binary, signs it with
a Developer ID, notarizes and staples the app and a drag-to-install DMG, signs
the app zip for the updater and publishes all of it as a GitHub release — see
[`docs/RELEASE.md`](docs/RELEASE.md). The icon — a
feather on a blue→indigo gradient — is drawn by `Scripts/icon_gen.swift`;
`build_app.sh` renders it into `Resources/Plume.icns` on the first build and
again whenever the generator changes.

## Updates and privacy

Once a day (and from Plume ▸ Check for Updates…) Plume asks
`api.github.com/repos/tuanlongsav/plume/releases/latest` whether a newer
version exists. The request carries no cookies, account or identifier — only a
`Plume/<version>` User-Agent — and can be turned off under Plume ▸ Check for
Updates Automatically. A download is installed only if its Ed25519 signature
matches the key built into the app and the app inside is signed by Plume's
Developer ID; local builds never update themselves.

## Architecture

The file-by-file map lives in [`AGENTS.md`](AGENTS.md#layout), next to the
rules that are easy to break when changing those files.

### Why no Rust

In a WebView wrapper, WebKit owns all networking to Facebook — there is no
protocol layer to implement, so a Rust "network core" would add build
weight without any speedup. Stripping tracker/ad/telemetry traffic does not
need one either: WebKit's `WKContentRuleList` compiles Safari content-blocker
rules (JSON) and applies them inside its own network process, by URL and
resource type. A separate local proxy would only see hostnames in HTTPS
unless it intercepted TLS, and would be one more process to sign and ship.

## Roadmap

- [ ] Tracker/ad blocking with `WKContentRuleList` (Safari content-blocker JSON)
- [x] Dark-mode / compact-density toggles
- [ ] Per-account profiles: a persistent `WKWebsiteDataStore(forIdentifier:)` per account
- [x] App icon + DMG packaging
