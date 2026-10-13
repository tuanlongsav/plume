# Plume

A lightweight, native macOS client for Facebook Messenger — like
[Caprine](https://github.com/sindresorhus/caprine), but without Electron.

Caprine bundles a full Chromium (~150 MB) per app. Plume wraps
`messenger.com` in the system **WebKit** (`WKWebView`) instead, so the app
is a few MB, starts fast, scrolls with native momentum, and shares the OS's
WebKit security updates. Pure Swift + AppKit — no runtime dependencies.

## Features

- Native `WKWebView` shell, persistent login (cookies survive relaunch)
- Real macOS notifications (the web `Notification` API is bridged to
  `UNUserNotificationCenter`); clicking a banner reopens that thread
- Dock unread badge, synced from the page's unread count
- Outbound links open in your default browser, not inside the app
- Native file picker for attachments; camera/mic granted for calls
- In-app PDF viewing for attachments (PDFKit); other files reveal in Finder
- Conversation keyboard shortcuts (⌘1–9 jump, next/previous, next unread, find)
- Always-on-top window; toolbar & theming toggles
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

bash Scripts/make_dmg.sh release       # → build/Plume.dmg (drag-to-install)
bash Scripts/make_icon.sh              # regenerate Resources/Plume.icns
```

Requires Xcode command-line tools (Swift 6). `build_app.sh` compiles with
SwiftPM, assembles the `.app` bundle with an `Info.plist` and app icon, and
ad-hoc signs it (needed for notifications and camera/mic TCC prompts).
`install.sh` runs that build, quits a running Plume, replaces the copy in
`/Applications` and opens it — login and settings carry over, though a new
ad-hoc signature can make macOS ask for camera/mic access again.
`make_dmg.sh` wraps that into a compressed DMG with an `/Applications`
symlink. The icon — a feather on a blue→indigo gradient — is drawn
programmatically by `Scripts/icon_gen.swift`; rerun `make_icon.sh` only when
the design changes (the committed `Resources/Plume.icns` is used otherwise).

## Architecture

| Piece | File |
|---|---|
| Process entry / `NSApplication` boot | `Sources/Plume/main.swift` |
| Window, menus, notification routing | `Sources/Plume/AppDelegate.swift` |
| `WKWebView` config, nav, uploads, badge | `Sources/Plume/WebViewController.swift` |
| Injected JS (notification + badge bridge) | `Sources/Plume/InjectedScript.swift` |
| URLs, user-agent, internal-host rules | `Sources/Plume/Constants.swift` |

### Why no Rust (yet)

In a WebView wrapper, WebKit owns all networking to Facebook — there is no
protocol layer to implement, so a Rust "network core" would add build
weight without any speedup. The place Rust *would* earn its keep is a
**Phase 2 local proxy** that strips Facebook tracker/ad/telemetry traffic
to make pages load lighter. That's real performance work and is kept out
of scope for v1.

## Roadmap

- [ ] Phase 2: Rust content-filtering proxy (tracker/ad stripping)
- [ ] Custom dark-mode / compact-density CSS toggles
- [ ] Per-account profiles (multiple `WKWebsiteDataStore`s)
- [x] App icon + DMG packaging
