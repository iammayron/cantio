import Foundation

enum PlayerState: String, Equatable {
    case playing
    case paused
    case stopped
    case unknown

    init(appleScriptValue raw: String) {
        switch raw.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

struct NowPlaying: Equatable {
    var trackId: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Double
    var positionSeconds: Double
    var state: PlayerState
    /// URL to the album artwork, exposed by Spotify's AppleScript dictionary
    /// as `artwork url`. Nil if the track has no artwork or the property
    /// fails (older Spotify builds).
    var artworkURL: String?
    var shuffling: Bool = false
    /// Spotify's AppleScript `repeating` is on/off only — no repeat-one.
    var repeating: Bool = false
    /// 0–100.
    var volume: Int = 100
}

/// Public web link for a Spotify URI, for sharing. Nil for URIs with no
/// public page (ads, local files).
func shareURL(for trackId: String) -> URL? {
    let parts = trackId.split(separator: ":")
    guard parts.count == 3, parts[0] == "spotify",
          parts[1] == "track" || parts[1] == "episode",
          !parts[2].isEmpty else { return nil }
    return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
}

enum SpotifyAvailability: Equatable {
    case available
    case notRunning
    case notInstalled
    /// macOS denied AppleEvents Automation permission for Spotify. The user
    /// must grant access in System Settings → Privacy & Security → Automation.
    case permissionDenied
}

/// Snapshot of the player position at a known wall-clock instant. Used to
/// extrapolate the current position between polls so synced lyrics can stay
/// within ±200 ms of Spotify without polling at high frequency.
struct PositionAnchor: Equatable {
    var position: Double
    var sampledAt: Date
    var isPlaying: Bool
}
