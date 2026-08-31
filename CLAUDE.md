# Cantio

Native macOS menu-bar app. Floats Spotify lyrics over the desktop in sync. Target user: Mac power user who lives in Spotify and wants karaoke-grade lyrics without giving up privacy or HIG-native feel. Design goals: Apple-HIG-native (looks like Apple shipped it), seamless (zero-config, lazy permissions, persistent across spaces), privacy-first (no telemetry, no analytics, only LRCLIB network egress).

## Build & run

```bash
xcodebuild -project /Users/mayron/projects/mayron/cantio/Cantio.xcodeproj \
  -scheme Cantio -configuration Debug \
  -derivedDataPath /Users/mayron/projects/mayron/cantio/.build build

killall Cantio 2>/dev/null; \
open /Users/mayron/projects/mayron/cantio/.build/Build/Products/Debug/Cantio.app
```

Tests: `xcodebuild -scheme Cantio test -derivedDataPath .build` (targets pending — see testing-strategy.md §10).

## Tech stack

- Swift 5.9+, SwiftUI primary, AppKit at bridge points (`NSWindow`, `NSVisualEffectView`, `NSHostingView`, `NSEvent` monitors, Carbon `RegisterEventHotKey`).
- macOS 14+ deployment target.
- SPM dependencies: `swift-snapshot-testing` (test target only). No runtime deps.
- AppleScript / Scripting Bridge for Spotify control. `SMAppService.mainApp` for launch-at-login. No third-party libs.

## Architecture overview

- `CantioApp` (`@main`) + `AppDelegate` bootstrap — single `Preferences.shared`, `SpotifyMonitor`, `LyricsStore`, `FloatingLyricsController` constructed in `bootstrapIfNeeded()`.
- `MenuBarExtra(.window)` panel rendered by `MenuBarPanel` (`.menuBarExtraStyle(.window)`); `WindowTransparencyApplier` walks ancestor `NSView` chain to clear opaque backings so material shows.
- `FloatingLyricsController` owns `FloatingLyricsWindow` — borderless, `.floating`, `canJoinAllSpaces`, `setFrameAutosaveName("CantioFloatingLyricsWindow")`, conditional click-through with Option-click toggle + per-pixel alpha hit-test for pill style.
- `SpotifyMonitor` polls via AppleScript / Scripting Bridge — exposes `availability` + `nowPlaying` as `@Published`. Permission-denied is a first-class state.
- `LyricsStore` binds to monitor; `LRCLibProvider` fetches; `LyricsCache` persists to disk (atomic, keyed by track id).
- `Preferences` (`@MainActor`, UserDefaults-backed `@Published`) — single source of truth. UI binds; controllers observe via Combine. Migrations at init only (legacy `windowPreset` → `windowStyle`+`backgroundStyle`).
- `FL.Palette` derives every color from `(tone, accentHue)` via OKLCH. Tone resolves from `prefs.tone` (auto/light/dark) and `colorScheme`.
- `Settings` scene + `SettingsLink` opens `SettingsView`. Activation policy flips `.regular`/`.accessory` so Settings appears in cmd-tab.

## Anti-patterns to avoid

- Never use custom blur — always `NSVisualEffectView` (`.popover` for menu, `.hudWindow` for floating). Set `state = .active`, `blendingMode = .behindWindow` for desktop overlays.
- Window must be `isOpaque = false` + `backgroundColor = .clear` for material to show through. SwiftUI re-installs opaque backing on `MenuBarExtra(.window)` — re-apply across runloop ticks (see `WindowTransparencyApplier`).
- Pill / fullscreen styles MUST set `window.hasShadow = false` then `invalidateShadow()` — rectangular `NSWindow` shadow halos the silhouette otherwise. Minimal keeps shadow.
- Settings opens via `SettingsLink` (NEVER `NSApp.activate` + open scene manually). Flip `setActivationPolicy(.regular)` on appear, `.accessory` on disappear.
- No inline RGB outside `FL.Palette`. All colors derive from palette (tone, hue). Documented edge cases only.
- No animation > 0.4s for routine state changes (karaoke is read-while-changing). Spring `.spring(response: 0.32, dampingFraction: 0.88)` default.
- Never honor-skip `accessibilityReduceMotion` / `accessibilityReduceTransparency` / `accessibilityIncreaseContrast`. Glass/pill degrade to solid when reduce-transparency on.
- No backwards-compat shims in code paths — migrations live ONLY at `Preferences.init` UserDefaults read time. Once migrated, the new key is canonical.
- Never hardcode accent (default blue). Always `prefs.accentHue` → palette.
- No docs/comments unless WHY is non-obvious (mechanism quirks, Apple framework gotchas). Code reads itself.
- No telemetry, no analytics, no crash reporters. Only documented network call: LRCLIB.
- Never mock `UserDefaults` — pass `UserDefaults(suiteName:)` (`Preferences.init` accepts injection). Never mock the file system in `LyricsCache` tests — use temp dir. Never mock `Date` via swizzle — pass explicitly.
- Hit targets ≥ 28pt. New text always carries VoiceOver label. Every action has keyboard equivalent.
- Don't add LaunchAgents plist for login — `SMAppService.mainApp` only.
- Don't request Spotify Automation permission at launch — lazily, on first use.
- **Never call `AEDeterminePermissionToAutomateTarget`.** It never returns against Spotify (1.2.98 / macOS 26) — not with `askUserIfNeeded: false`, not with a runloop on the calling thread. It hung `SpotifyMonitor.poll()` on its first iteration, so `availability` stayed at its init value and the app silently showed "Spotify not running" forever, with zero AppleEvents traffic in `tccd`. Derive permission from the AppleEvent error of a *real* read instead (`-1743` denied, `-1744` not determined) and always set `SBApplication.timeout` so a wedged target can't stall the loop.
- Any blocking call inside the poll loop must be bounded. A hung poll is invisible — no crash, no log, just a stale `@Published`.
- `PrefRow`'s `sub` wraps (`.fixedSize(horizontal: false, vertical: true)`); text in a `PrefRow` control that must not be squeezed out by sibling buttons needs `.fixedSize()`.

## Workflow rules

See `docs/claude-workflow.md`. Summary:

- Plan mode default for non-trivial changes (`Shift+Tab` ×2). Tighten plan with lead, then auto-accept.
- Verification loop is non-negotiable — every change ends with `xcodebuild` + tests + (if UI) snapshot diff.
- Slash commands in `.claude/commands/` for repeats: `/build-and-run`, `/test-cantio`, `/snapshot-record`, `/hig-check`, `/commit-cantio`.
- Hooks (`.claude/settings.json`): PostToolUse swift-format on `*.swift`; Stop hook reminds to test if uncommitted Swift changes; PreToolUse blocks `git commit` if build stale.
- Pre-allow `Bash(xcodebuild:*)`, `Bash(killall Cantio)`, etc. — don't `--dangerously-skip-permissions`.
- End-of-session: log every wrong assumption Claude made into this file.

## Testing rules

See `docs/testing-strategy.md`. Summary:

- Pyramid: XCTest unit (85% pure-logic) → snapshot (full prefs matrix per view) → XCUITest (smoke flows only).
- Protocol-DI at the seams: `PlaybackSource` (SpotifyMonitor), `LyricsProvider` (LRCLibProvider). Controllers + stores accept protocol, not concrete.
- Snapshot matrix: `windowStyle × backgroundStyle × tone × state × accentHue(2) × linesVisible(1,3) × fontSize(small,large)` ≈ 60 snapshots.
- Mock at protocol seam, never mid-type. Never mock `UserDefaults` — `suiteName` per test. Never mock filesystem — temp dir. Never swizzle `Date` — pass explicitly. Always mock AppleScript exec, network, Carbon hot-key reg.
- CI gates: snapshot diff present → fail; coverage drop > 2% → fail; UI test fail → fail.
- Test naming: `test_<unit>_<condition>_<expected>()`.

## HIG rules

See `docs/apple-hig-checklist.md`. Quick-reject auto-fails:

- Custom blur instead of `NSVisualEffectView`.
- Inline RGB outside palette.
- Animation > 0.5s for routine state.
- Missing reduce-motion / reduce-transparency honoring.
- New text without VoiceOver label.
- Hit target < 28pt.
- New control without keyboard equivalent.
- Network call to undocumented host.
- Menu-bar action > 1 step deep without shortcut.

Validate every UI change across the matrix in §13 before declaring done.

## Spawning agents

Defined under `.claude/agents/`:

- `swift-builder` — verify build compiles + report errors. Spawn after every Swift edit batch. Haiku-class, mechanical.
- `hig-reviewer` — Apple HIG audit on uncommitted diff. Spawn for every UI change. Opus-class, judgment.
- `a11y-auditor` — Reduce Motion / Reduce Transparency / VoiceOver / contrast check. Spawn parallel to hig-reviewer for UI changes.
- `test-author` — write XCTest + snapshot updates for changed code paths. Spawn after logic changes. Sonnet-class.
- `regression-auditor` — quarterly: snapshot drift vs last release, untested code map, re-verify past bug fixes. Spawn via `/gap-audit`.

Parallelize (`hig-reviewer` + `a11y-auditor` + `test-author`) for cross-cutting UI changes. Don't over-spawn for routine fixes.

## Memory protocol

When Claude makes a wrong assumption — append the corrected rule to "Anti-patterns to avoid" (or the relevant section). CLAUDE.md is team memory: it grows with the project. Every burned-in lesson stays here so the next session never relearns it. After every PR, ask "what did Claude get wrong that the docs should have prevented?" and add it.
