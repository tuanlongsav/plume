# AGENTS.md — Plume

Instructions for AI coding agents (Codex, Gemini CLI, Cursor, Claude Code, …)
working in this repository. The human-facing overview is in `README.md`.

**This is the only agent-instruction file.** Don't add `CLAUDE.md`,
`CLAUDE.local.md`, `GEMINI.md`, `.cursorrules` or `.cursor/rules/` — edit this
file instead. Codex and Cursor read it natively; Claude Code reads it when no
`CLAUDE.md`/`CLAUDE.local.md` exists (v2.1.277+), so adding one hides this
file from Claude; Gemini CLI reads it through `.gemini/settings.json`.

## Project

A native macOS client for Facebook Messenger: `messenger.com`, or
`facebook.com/messages` for accounts Meta has moved there (from April 2026),
inside the system `WKWebView`, with native chrome, notifications, dock badge, PDF viewer,
an Android-style "chat heads" bubble mode and a self-updater fed by GitHub
Releases. Pure Swift + AppKit, no runtime dependencies (the updater uses only
CryptoKit and Security, which ship with macOS).

- SwiftPM, `swift-tools-version:6.0`, but **Swift 5 language mode**
  (`.swiftLanguageMode(.v5)`): strict concurrency checking is off.
- Minimum macOS 13.3, set only in `Package.swift`: its system WebKit (Safari
  16.4) is the oldest Facebook serves Messenger to. The injected scripts must
  stay within Safari 16.4 (`WebFloorTests`). Builds record SDK 14.0 for
  linked-on-or-after behaviour (`build_app.sh` `SDK_STAMP`). Bundle id
  `com.htl.plume`.
- AppKit/WebKit only build on macOS. On any other machine you can read and
  edit, but you cannot compile or test — say so instead of claiming it builds.

## Commands (macOS)

| Task | Command |
|---|---|
| Unit tests | `swift test` |
| Build the `.app` | `bash Scripts/build_app.sh release` → `build/Plume.app` (`debug` also works) |
| Build and install/update in `/Applications` | `bash Scripts/install.sh` (a local `0.0.0` build; refuses to replace an installed release unless `PLUME_REPLACE_RELEASE=1`) |
| Developer ID signed + notarized `Plume-X.Y.dmg` and updater `Plume-X.Y.zip` | `bash Scripts/release_sign.sh X.Y` (needs the cert and the `vkey` notarytool profile) |
| Publish a release to GitHub (build, Ed25519 manifest, tag, `gh release create`, verify) | `bash Scripts/release.sh X.Y --no-publish` builds a notarized candidate; after testing it, `bash Scripts/release.sh X.Y --from-build` publishes exactly those files. Steps in `docs/RELEASE.md` |
| Update-signing key / signatures | `swift Scripts/update_sign.swift keygen\|pubkey\|sign\|verify …` |
| Regenerate the icon | `bash Scripts/make_icon.sh` (`build_app.sh` runs it when `Resources/Plume.icns` is missing; the `.icns` is generated, not committed) |

Environment knobs: `PLUME_UNIVERSAL=1` (arm64 + x86_64), `PLUME_SIGN_IDENTITY`
(Developer ID instead of ad-hoc), `PLUME_INSTALL_DIR` (default `/Applications`),
`PLUME_NOTARY_PROFILE` (notarytool keychain profile, default `vkey`),
`PLUME_VERSION` (`MAJOR.MINOR`; unset means `0.0.0`, a local build the updater
never replaces), `PLUME_UPDATE_KEY` (path of the Ed25519 private key),
`PLUME_RELEASE_REPO` (default `tuanlongsav/plume`; any other repo is a test
run that does not tag origin), `PLUME_REPLACE_RELEASE=1` (let `install.sh`
replace an installed release).

CI (`.github/workflows/ci.yml`, `macos-15` runner) runs `swift test`, a
stamped release build, the update-signing and bundle-swap round trips and a
bash 3.2 syntax check on every pull request and every push to `main`. It is a
backstop, not a substitute: before
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
| `ChatBubbleController.swift` | Bubble mode controller: chain membership, frame loop (`CADisplayLink`), card, hover, gestures, multi-display follow |
| `Chain.swift`, `BubbleChipView.swift`, `BubblePanels.swift`, `ConversationPicker.swift`, `BubbleConversation.swift`, `BubbleOverlay.swift` | Bubble-mode parts: chain geometry and springs, one chat head, the card/bubble/tether panels, the conversation list, the snapshot model and avatar cache, overlay level and `ChipMenuLift` |
| `PlumeTrace.swift` | DEBUG-only multi-display trace log (no-op in release) |
| `BubbleChainSync.swift`, `DisplayHop.swift`, `ThreadURL.swift`, `ThreadDelete.swift` | Small pure-logic helpers, unit-tested. `ThreadURL` knows both Messenger sites (`messenger.com/t/…`, `facebook.com/messages/t/…`) and which pages are the chat pages |
| `Constants.swift` | Home URL, user agent, internal/call/attachment host rules |
| `Preferences.swift` | `UserDefaults`-backed settings |
| `Theme.swift` | Design tokens and the `L.t(vi, en)` localisation helper |
| `ChromeToolbar.swift`, `StateOverlays.swift`, `FeatherView.swift` | Native toolbar, loading/offline/splash overlays, logo |
| `PDFViewerWindowController.swift` | In-app PDF viewer for attachments |
| `PopupWindowController.swift` | Real windows for `window.open` (calls start on `about:blank`) |
| `Updater.swift` | Self-update: GitHub check, download, verification, atomic swap, relaunch; progress panel |
| `AppVersion.swift`, `UpdateFeed.swift`, `UpdateVerifier.swift` | Pure updater logic (version order, release selection, daily throttle, manifest + Ed25519 checks), unit-tested |
| `UpdateKeys.swift` | The embedded Ed25519 public key for update archives |
| `CHANGELOG.md`, `docs/RELEASE.md` | Release notes shown in the update prompt; the release procedure (Vietnamese) |
| `Tests/PlumeTests/` | XCTest; JS that needs no DOM is run in `JavaScriptCore` |

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
4. **Never `webView.load()` a thread URL while the page is on the messages
   pages** (`ThreadURL.isMessagesSurface`). A full reload empties the inbox
   DOM and the next snapshot deletes every bubble. Open threads with
   `__plumeOpenThread` (clicks the inbox row). Off those pages (a Facebook
   profile or post opened from a chat) there is no inbox to lose, and loading
   is the only way back.
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
   (the frame loop runs on a `BubbleFrameDriver`: a display link on macOS
   14+, a 60 Hz timer on 13; both call back weakly). Anything that runs for the
   whole of bubble mode needs a timer tolerance and must do no work when idle.
8. **Privacy.** `PlumeTrace.log` is DEBUG-only; never write contact names,
   message text or cursor positions to disk in release builds. Conversation
   snapshots never leave the machine.
9. **User-facing strings are bilingual**: `L.t("Tiếng Việt", "English")`.
10. **Updates.** Never change `UpdateKeys.publicKeyBase64` without the
    rotation steps in `docs/RELEASE.md`: installed copies trust only the key
    they embed. Never rebuild or re-upload a version that is already published
    (new bytes, new signature). The update check sends nothing but a
    User-Agent, at most once a day (`releases/latest`, plus the candidate's
    manifest when there is a newer version, so a release this Mac cannot run
    is never offered), and runs no timer. Never raise the minimum macOS
    without `release.sh --raise-floor` and a note for the Macs left behind. `0.0.0`, ad-hoc and
    translocated copies never update themselves.
11. **Put logic where it can be tested.** Prefer small pure types
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
