# AGENTS.md — Plume

Instructions for AI coding agents (Codex, Gemini CLI, Cursor, Claude Code, …)
working in this repository. The human-facing overview is in `README.md`.

**This is the only agent-instruction file.** Don't add `CLAUDE.md`,
`CLAUDE.local.md`, `GEMINI.md`, `.cursorrules` or `.cursor/rules/` — edit this
file instead. Codex and Cursor read it natively; Claude Code reads it when no
`CLAUDE.md`/`CLAUDE.local.md` exists (v2.1.277+), so adding one hides this
file from Claude; Gemini CLI reads it through `.gemini/settings.json`.

## Project

A native macOS client for Facebook Messenger: `messenger.com` inside the
system `WKWebView`, with native chrome, notifications, dock badge, PDF viewer
and an Android-style "chat heads" bubble mode. Pure Swift + AppKit, no runtime
dependencies.

- SwiftPM, `swift-tools-version:6.0`, but **Swift 5 language mode**
  (`.swiftLanguageMode(.v5)`): strict concurrency checking is off.
- Minimum macOS 14. Bundle id `com.htl.plume`.
- AppKit/WebKit only build on macOS. On any other machine you can read and
  edit, but you cannot compile or test — say so instead of claiming it builds.

## Commands (macOS)

| Task | Command |
|---|---|
| Unit tests | `swift test` |
| Build the `.app` | `bash Scripts/build_app.sh release` → `build/Plume.app` (`debug` also works) |
| Build and install/update in `/Applications` | `bash Scripts/install.sh` |
| Drag-to-install DMG (universal, ad-hoc signed) | `bash Scripts/make_dmg.sh` → `build/Plume.dmg` |
| Developer ID signed + notarized DMG | `bash Scripts/release_sign.sh` (needs the cert and the `vkey` notarytool profile) |
| Regenerate the icon | `bash Scripts/make_icon.sh` (only when the design changes) |

Environment knobs: `PLUME_UNIVERSAL=1` (arm64 + x86_64), `PLUME_SIGN_IDENTITY`
(Developer ID instead of ad-hoc), `PLUME_INSTALL_DIR` (default `/Applications`).

CI (`.github/workflows/ci.yml`, `macos-15` runner) runs `swift test` and
`bash Scripts/build_app.sh release` on every push and pull request, and keeps
the zipped `.app` as a run artifact. It is a backstop, not a substitute: before
calling a change done, run `swift test` and a release build locally. From a
non-macOS machine, push and read the CI result instead of claiming it builds.
Debug builds set `WKWebView.isInspectable`, so Safari ▸ Develop can attach to
the page. Scripts must stay compatible with the bash 3.2 that ships with macOS.

## Layout

| File | What lives there |
|---|---|
| `Sources/Plume/main.swift` | `NSApplication` boot |
| `AppDelegate.swift` | Main window, menus, notification routing, bubble-mode switching |
| `WebViewController.swift` | `WKWebView` config, navigation, downloads, badge, script-message bridge |
| `InjectedScript.swift` | All JS/CSS injected into the page (notification bridge, conversation snapshot, theatre detection, delete-chat flow) |
| `ChatBubbleController.swift` | Bubble mode: chain physics (`Chain`, `CADisplayLink`), card panel, conversation picker, multi-display follow |
| `BubbleChainSync.swift`, `DisplayHop.swift`, `ThreadURL.swift`, `ThreadDelete.swift` | Small pure-logic helpers, unit-tested |
| `Constants.swift` | Home URL, user agent, internal/call/attachment host rules |
| `Preferences.swift` | `UserDefaults`-backed settings |
| `Theme.swift` | Design tokens and the `L.t(vi, en)` localisation helper |
| `ChromeToolbar.swift`, `StateOverlays.swift`, `FeatherView.swift` | Native toolbar, loading/offline/splash overlays, logo |
| `PDFViewerWindowController.swift` | In-app PDF viewer for attachments |
| `PopupWindowController.swift` | Real windows for `window.open` (calls start on `about:blank`) |
| `Tests/PlumeTests/` | XCTest; JS that needs no DOM is run in `JavaScriptCore` |
| `docs/ui-redesign-brief.md` | Design brief (Vietnamese) |

## Rules that are easy to break

1. **Injected CSS is a performance hazard.** Messenger is a huge virtualised
   React app; every selector is re-matched against thousands of nodes while it
   paginates. Keep rules few, narrowly scoped, never universal, and never
   per-message decoration. Read the note on `InjectedScript.StyleID` before
   adding any.
2. **No standing work in the page.** No document-wide `MutationObserver`,
   `setInterval` or `requestAnimationFrame` loops. Native code asks the page
   on demand via `evaluateJavaScript`. A callback that writes to the DOM it
   observes re-triggers itself — even `classList.remove` of an absent class
   rewrites the attribute — and that once shipped as a 60 fps loop. Write only
   when the value actually changes (see `__plumeSetStyle`).
3. **Hook the page by role/ARIA/attributes, never by Messenger's hashed class
   names**, which change constantly.
4. **Never `webView.load()` a thread URL on a live session.** A full reload
   empties the inbox DOM and the next snapshot deletes every bubble. Open
   threads with `__plumeOpenThread` (clicks the inbox row).
5. **Destructive flows click only exact matches.** Delete-chat matches by role
   plus exact, accent-folded label and backs out without clicking anything if
   a step's control is missing. Keep `ThreadDeleteTests` passing.
6. **Host rules** (`Constants.swift`): `fbsbx.com` must stay out of
   `internalHosts`; camera/mic are auto-granted only to `callHosts`. Covered by
   `HostRulesTests`.
7. **Bubble mode shares one web view** between the main window and the card.
   Bubbles and card sit at `.screenSaver` level with `canJoinAllSpaces` +
   `fullScreenAuxiliary` (`PlumeOverlay`); menus must be lifted above them
   (`ChipMenuLift`). Timers, observers and display links capture `[weak self]`
   (the display link goes through `LinkProxy`). Anything that runs for the
   whole of bubble mode needs a timer tolerance and must do no work when idle.
8. **Privacy.** `PlumeTrace.log` is DEBUG-only; never write contact names,
   message text or cursor positions to disk in release builds. Conversation
   snapshots never leave the machine.
9. **User-facing strings are bilingual**: `L.t("Tiếng Việt", "English")`.
10. **Put logic where it can be tested.** Prefer small pure types
    (`ThreadURL`, `BubbleChainSync`, `DisplayHop`, `Chain.dockedRowXs`) with
    tests in `Tests/PlumeTests`, over logic buried in AppKit code.

## Code style

- Match the surrounding code. Comments explain *why* — the constraint or the
  bug a line prevents — not what the code does.
- Comments like "Removed for performance" record decisions; don't bring that
  code back without dealing with the reason given.
- Keep diffs minimal and focused. No new dependencies.

## Commits

- Subject: one imperative sentence ending in a period, e.g.
  `Add whole-conversation delete; let the bubble chain stay on a chosen display.`
- Body: wrapped prose explaining the problem and why the change fixes it.
- Never commit `build/` or `.build/`.

## Talking to the maintainer

Reply in Vietnamese. Keep technical terms, commands, code, file paths and
proper names as they are (don't translate them).
