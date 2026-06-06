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
- Remembers window size & position; full-screen, back/forward, reload

## Build

```sh
bash Scripts/build_app.sh release     # → build/Plume.app
open build/Plume.app
```

Requires Xcode command-line tools (Swift 6). The script compiles with
SwiftPM, assembles the `.app` bundle with an `Info.plist`, and ad-hoc
signs it (needed for notifications and camera/mic TCC prompts).

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
- [ ] App icon + DMG packaging
