<p align="center">
  <img src="docs/assets/icon.png" width="140" alt="Cantio icon" />
</p>

<h1 align="center">Cantio</h1>

<p align="center">
  <em>Karaoke-grade Spotify lyrics, floating over your desktop.</em>
</p>

<p align="center">
  Time-synced lyrics in a menu-bar app that looks like Apple shipped it.<br/>
  Reads Spotify locally — no Web API, no OAuth, no telemetry.
</p>

<p align="center">
  <a href="https://github.com/iammayron/cantio/releases/latest"><img src="https://img.shields.io/github/v/release/iammayron/cantio" alt="Release"></a>
  <a href="https://github.com/iammayron/cantio/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/universal-arm64%20%7C%20x86__64-blue" alt="Universal">
</p>

<p align="center">
  <img src="docs/assets/fullscreen.png" width="49%" alt="Cantio fullscreen karaoke view" />
  <img src="docs/assets/pill.jpg" width="49%" alt="Cantio floating lyrics pill over the desktop" />
  <br/>
  <em>Fullscreen karaoke view · floating pill over the desktop</em>
</p>

---

Cantio shows the lyrics of whatever's playing in Spotify, synced line-by-line, in a floating pill over your desktop — or a fullscreen karaoke view with an album-art-tinted backdrop. It reads the track straight from the local Spotify app over AppleScript, so there are no API keys, no logins, and the only thing it ever sends over the network is a lyrics lookup to [LRCLIB](https://lrclib.net).

## Install

### Homebrew (recommended)

```sh
brew install --cask iammayron/tap/cantio
xattr -dr com.apple.quarantine /Applications/Cantio.app
```

Cantio isn't signed with a paid Apple Developer ID, so macOS quarantines it. The `xattr` step clears that so the app launches (Homebrew dropped the `--no-quarantine` flag, so it now runs as a separate step). Update later with `brew upgrade`.

### Manual

Download the DMG from the [latest release](https://github.com/iammayron/cantio/releases/latest), drag **Cantio** to Applications, then on first launch **right-click → Open** (or run):

```sh
xattr -dr com.apple.quarantine /Applications/Cantio.app
```

Cantio lives in the menu bar (no Dock icon) — look for the music-note glyph.

## Features

<img src="docs/assets/menu.png" align="right" width="280" alt="Cantio menu-bar panel" />

- **Synced lyrics** — line-by-line highlight that tracks playback position
- **Two looks** — a draggable floating pill, or a fullscreen karaoke view
- **Fullscreen karaoke** — large lyrics, album-art-tinted floating backdrop, auto-hiding transport controls (play/pause, ±10s seek, prev/next) and a scrubber
- **Menu-bar controls** — playback, scrubber, and quick toggles from the status item
- **Double-click the pill** to go fullscreen; double-click or `Esc` to come back
- **Native feel** — glass materials, alignment guides while dragging, honors Reduce Motion / Reduce Transparency / VoiceOver
- **Private by design** — playback read locally via AppleScript; the only network call is the LRCLIB lyrics lookup

<br clear="all" />

## How it works

| Piece | What it does |
|-------|--------------|
| `SpotifyMonitor` | Polls the local Spotify app over AppleScript for the now-playing track + position |
| `LyricsService` | Fetches timed lyrics from LRCLIB, cached to disk per track |
| `FloatingLyricsController` | Owns the borderless overlay window (pill / fullscreen), drag + click-through |
| `ArtworkColors` | Derives the backdrop hues from the album cover |

Spotify automation permission is requested lazily on first use, never at launch.

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Cantio.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project Cantio.xcodeproj -scheme Cantio -configuration Debug build
```

`Cantio.xcodeproj` is generated — edit `project.yml`, not the pbxproj.

### Packaging

```sh
scripts/build-unsigned.sh    # ad-hoc-signed universal DMG (what releases ship)
```

`scripts/build-release.sh` is the notarized path (hardened runtime, Developer ID, stapled) for when a paid Apple Developer account is available — see the script header for the required env vars.

## License

MIT — see [LICENSE](LICENSE).
