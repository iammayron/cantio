---
description: Spotify integration rules for Cantio. Loaded when editing files in Cantio/Spotify/.
globs: Cantio/Spotify/**/*.swift
---

# Spotify rules — Cantio

## Source of truth

- Cantio reads playback via **AppleScript scripting bridge** to the Spotify app — local only, no API tokens, no network for playback.
- `SpotifyMonitor` owns polling + state. `NowPlaying` is the snapshot type.
- Lyrics fetched from LRCLIB (separate concern — see `LyricsService`).

## Permissions

- TCC: `com.apple.security.scripting-targets` entitlement + `com.apple.spotify.client` target.
- Permission requested **lazily** on first script run, not at launch.
- States: `.available`, `.notInstalled`, `.notRunning`, `.permissionDenied`.
- `.permissionDenied` recovery: explain + `SpotifyPermission.openSystemSettings()` button.
- Never nag-loop the permission prompt.

## AppleScript

- Run via `NSAppleScript` from a background queue. UI updates on `MainActor`.
- Scripts must be idempotent and tolerate Spotify being not-running.
- Parse output defensively — Spotify may return empty fields, unexpected encodings, or partial state during track transitions.
- Extract pure parser into `parseScriptOutput(String) -> PollResult` — testable without `NSAppleScript`.

## Polling

- Default cadence: ~1 Hz when playing, slower (or paused) when not.
- Interpolate position locally between polls via `PositionAnchor` — don't poll faster.
- Anchor invalidates on track change, pause, scrub.
- `interpolatedPosition(now:)` should be a free function for testability — no `SpotifyMonitor` instance required.

## NowPlaying

- Identity: `trackId` (Spotify URI). Title + artist + album are display-only.
- `state` enum: `.playing`, `.paused`, `.stopped`.
- `durationSeconds == 0` is valid (transient state) — guard before division.
- `artworkURL` may be nil or stale — UI must tolerate.

## Anti-patterns

- Network calls to Spotify Web API — out of scope, breaks privacy promise.
- Caching OAuth tokens — not used.
- Polling while screen locked / app inactive — waste.
- Assuming `nowPlaying != nil` after `.available` — not guaranteed during transitions.
- Coupling `SpotifyMonitor` to AppKit `NSWindow` — keep it pure for testing.
- Writing `parseScriptOutput` inline inside `runScript` — extract for unit tests.
