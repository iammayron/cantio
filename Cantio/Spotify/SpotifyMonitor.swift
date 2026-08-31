import AppKit
import Foundation
import ScriptingBridge

private let spotifyBundleId = "com.spotify.client"

@objc private enum SpotifyScriptingPlayerState: Int {
    case stopped = 0x6b505353 // 'kPSS'
    case playing = 0x6b505350 // 'kPSP'
    case paused = 0x6b505370  // 'kPSp'
}

/// Result of a single Spotify poll. Lifted to file scope so the parser is
/// testable without an `NSAppleScript` instance.
enum SpotifyPollResult: Equatable {
    case notInstalled
    case notRunning
    case permissionNotDetermined
    case permissionDenied
    case running(NowPlaying)
}

/// Parses raw AppleScript output text into a `SpotifyPollResult`. Pure —
/// no `NSAppleScript`, no AppKit, no Date. Spotify's script returns either
/// a sentinel (`ERR_NOT_RUNNING` / `ERR_NO_TRACK`) or 7–8 newline-separated
/// fields: state, id, name, artist, album, position(sec), duration(ms or sec),
/// artworkURL?
func parseSpotifyScriptOutput(_ raw: String) -> SpotifyPollResult {
    if raw == "ERR_NOT_RUNNING" { return .notRunning }
    if raw == "ERR_NO_TRACK" { return .notRunning }
    let parts = raw.components(separatedBy: "\n")
    guard parts.count >= 7 else { return .notRunning }
    let posSeconds = Double(parts[5].trimmingCharacters(in: .whitespaces)) ?? 0
    let durRaw = Double(parts[6].trimmingCharacters(in: .whitespaces)) ?? 0
    // Spotify reports `duration` in milliseconds.
    let durSeconds = durRaw > 1_000 ? durRaw / 1_000.0 : durRaw
    let artURL: String? = parts.count >= 8
        ? {
            let s = parts[7].trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }()
        : nil
    let np = NowPlaying(
        trackId: parts[1],
        title: parts[2],
        artist: parts[3],
        album: parts[4],
        durationSeconds: durSeconds,
        positionSeconds: posSeconds,
        state: PlayerState(appleScriptValue: parts[0]),
        artworkURL: artURL
    )
    return .running(np)
}

/// Extrapolates playback position from an anchor at `now`. Pure — no
/// `SpotifyMonitor` instance needed. Position only advances while the
/// anchor's `isPlaying` is true.
func extrapolatePosition(anchor: PositionAnchor?, now: Date) -> Double? {
    guard let anchor else { return nil }
    guard anchor.isPlaying else { return anchor.position }
    let delta = now.timeIntervalSince(anchor.sampledAt)
    return anchor.position + max(0, delta)
}

/// Anything that emits `NowPlaying?` change events and accepts transport
/// commands. Real impl: `SpotifyMonitor`. Test impl: a stream-backed stub
/// injected into `LyricsStore.bind(to:)` and the menu-bar controls.
@MainActor
protocol PlaybackSource: AnyObject {
    var events: AsyncStream<NowPlaying?> { get }

    /// Toggles play/pause. Implementations should be optimistic — flip the
    /// observable state immediately, then rely on the next poll to reconcile.
    /// `onError` runs on the MainActor when AppleScript dispatch fails so the
    /// caller can roll back its optimistic UI flip.
    func playPause(onError: @escaping @MainActor (Error) -> Void)
    /// Skips to the previous track. Optimistic; reconciles on next poll.
    func previousTrack(onError: @escaping @MainActor (Error) -> Void)
    /// Skips to the next track. Optimistic; reconciles on next poll.
    func nextTrack(onError: @escaping @MainActor (Error) -> Void)
    /// Sets player position in seconds. Caller is responsible for throttling.
    func seek(to seconds: Double, onError: @escaping @MainActor (Error) -> Void)
}

/// Errors emitted by `SpotifyMonitor` transport commands.
enum PlaybackCommandError: Error, Equatable {
    case notAvailable
    case scriptFailed(code: Int, message: String?)
}

/// Observes the local Spotify desktop app via AppleScript.
/// Polls at ~500 ms while playing, ~2 s while paused, ~5 s when not running.
@MainActor
final class SpotifyMonitor: ObservableObject, PlaybackSource {
    @Published private(set) var availability: SpotifyAvailability = .notRunning
    @Published private(set) var nowPlaying: NowPlaying?
    /// Anchor used to extrapolate the current playback position between polls.
    /// Updated whenever a fresh poll arrives.
    @Published private(set) var positionAnchor: PositionAnchor?
    /// Current AppleEvents automation permission for Spotify.
    /// `.notDetermined` until the first prompt resolves; `.denied` when the
    /// user has refused or revoked access in System Settings.
    @Published private(set) var permission: AutomationPermission = .targetNotRunning

    /// When `false`, polling only *queries* permission state and never surfaces
    /// the system consent prompt. Onboarding holds this off so the prompt fires
    /// solely from its dedicated Spotify step — not as a standalone popup over
    /// the desktop. Re-enabled once onboarding completes so a later revoke/reset
    /// can still re-prompt on first use.
    var allowsPermissionPrompt = true

    private var task: Task<Void, Never>?
    private var lastEmitted: NowPlaying?

    private let playingInterval: UInt64 = 500_000_000      // 500 ms
    private let pausedInterval: UInt64 = 2_000_000_000     // 2 s
    private let idleInterval: UInt64 = 5_000_000_000       // 5 s

    /// AsyncStream of change events. Emits initial value plus every distinct update.
    let events: AsyncStream<NowPlaying?>
    private let eventsContinuation: AsyncStream<NowPlaying?>.Continuation

    init() {
        var cont: AsyncStream<NowPlaying?>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventsContinuation = cont
    }

    deinit {
        eventsContinuation.finish()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        eventsContinuation.finish()
    }

    private func loop() async {
        while !Task.isCancelled {
            let snapshot = await poll()
            apply(snapshot)
            let delay: UInt64
            switch (availability, nowPlaying?.state) {
            case (.available, .playing): delay = playingInterval
            case (.available, _): delay = pausedInterval
            default: delay = idleInterval
            }
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func apply(_ result: SpotifyPollResult) {
        switch result {
        case .notInstalled:
            if availability != .notInstalled { availability = .notInstalled }
            if nowPlaying != nil { nowPlaying = nil }
            if positionAnchor != nil { positionAnchor = nil }
            if permission != .targetNotRunning { permission = .targetNotRunning }
            emitIfChanged(nil)
        case .notRunning:
            if availability != .notRunning { availability = .notRunning }
            if nowPlaying != nil { nowPlaying = nil }
            if positionAnchor != nil { positionAnchor = nil }
            if permission != .targetNotRunning { permission = .targetNotRunning }
            emitIfChanged(nil)
        case .permissionNotDetermined:
            if availability != .notRunning { availability = .notRunning }
            if nowPlaying != nil { nowPlaying = nil }
            if positionAnchor != nil { positionAnchor = nil }
            if permission != .notDetermined { permission = .notDetermined }
            emitIfChanged(nil)
        case .permissionDenied:
            if availability != .permissionDenied { availability = .permissionDenied }
            if nowPlaying != nil { nowPlaying = nil }
            if positionAnchor != nil { positionAnchor = nil }
            if permission != .denied { permission = .denied }
            emitIfChanged(nil)
        case .running(let np):
            if availability != .available { availability = .available }
            if permission != .granted { permission = .granted }
            if nowPlaying != np { nowPlaying = np }
            updateAnchor(for: np)
            emitIfChanged(np)
        }
    }

    /// Re-anchors playback position. Called on every poll so UI extrapolation
    /// stays within Spotify's reported truth (±poll-jitter, ~tens of ms).
    private func updateAnchor(for np: NowPlaying) {
        positionAnchor = PositionAnchor(
            position: np.positionSeconds,
            sampledAt: Date(),
            isPlaying: np.state == .playing
        )
    }

    /// Returns the extrapolated playback position at `now`, advancing only
    /// while the player is in the `playing` state. Thin wrapper around the
    /// pure free function — see `interpolatedPosition(anchor:now:)`.
    func interpolatedPosition(now: Date = Date()) -> Double? {
        extrapolatePosition(anchor: positionAnchor, now: now)
    }

    private func emitIfChanged(_ value: NowPlaying?) {
        if value != lastEmitted {
            lastEmitted = value
            eventsContinuation.yield(value)
        }
    }

    // MARK: - Polling

    private func poll() async -> SpotifyPollResult {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleId) == nil {
            return .notInstalled
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleId).isEmpty {
            return .notRunning
        }
        // The *first* AppleEvent to Spotify surfaces the TCC consent prompt —
        // and a ScriptingBridge read is an AppleEvent. Onboarding holds the
        // read off entirely so the prompt fires from its dedicated Spotify
        // step, never as a standalone popup over the splash. There is no
        // no-ask precheck: `AEDeterminePermissionToAutomateTarget` never
        // returns against Spotify (see `SpotifyPermission`), so permission is
        // read back off the event error instead.
        guard allowsPermissionPrompt else { return .permissionNotDetermined }
        return await runSpotifyScript()
    }

    private func runSpotifyScript() async -> SpotifyPollResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.readSpotifyNowPlaying())
            }
        }
    }

    #if DEBUG
    /// Seeds availability + now-playing state for tests that exercise the
    /// transport layer without running the real polling loop. Internal so
    /// `@testable import Cantio` can reach it; not part of the shipped API.
    func _setStateForTesting(availability: SpotifyAvailability, nowPlaying: NowPlaying?) {
        self.availability = availability
        self.nowPlaying = nowPlaying
        if let np = nowPlaying { updateAnchor(for: np) }
    }
    #endif

    // MARK: - Transport commands

    func playPause(onError: @escaping @MainActor (Error) -> Void = { _ in }) {
        guard availability == .available else {
            onError(PlaybackCommandError.notAvailable)
            return
        }
        // Optimistic flip — anchor must follow so interpolation matches.
        if var np = nowPlaying {
            let newState: PlayerState = (np.state == .playing) ? .paused : .playing
            np.state = newState
            nowPlaying = np
            updateAnchor(for: np)
        }
        runCommandScript("""
        tell application id "com.spotify.client"
            if it is running then playpause
        end tell
        """, onError: onError)
    }

    func previousTrack(onError: @escaping @MainActor (Error) -> Void = { _ in }) {
        guard availability == .available else {
            onError(PlaybackCommandError.notAvailable)
            return
        }
        runCommandScript("""
        tell application id "com.spotify.client"
            if it is running then previous track
        end tell
        """, onError: onError)
    }

    func nextTrack(onError: @escaping @MainActor (Error) -> Void = { _ in }) {
        guard availability == .available else {
            onError(PlaybackCommandError.notAvailable)
            return
        }
        runCommandScript("""
        tell application id "com.spotify.client"
            if it is running then next track
        end tell
        """, onError: onError)
    }

    func seek(to seconds: Double, onError: @escaping @MainActor (Error) -> Void = { _ in }) {
        guard availability == .available else {
            onError(PlaybackCommandError.notAvailable)
            return
        }
        let clamped = max(0, seconds)
        // Optimistic anchor update so the scrubber doesn't snap back during
        // the AppleScript round trip.
        if var np = nowPlaying {
            np.positionSeconds = clamped
            nowPlaying = np
            updateAnchor(for: np)
        }
        let pos = String(format: "%.2f", clamped)
        runCommandScript("""
        tell application id "com.spotify.client"
            if it is running then set player position to \(pos)
        end tell
        """, onError: onError)
    }

    private func runCommandScript(_ source: String,
                                  onError: @escaping @MainActor (Error) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            _ = script?.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                let msg = error[NSAppleScript.errorMessage] as? String
                Task { @MainActor in
                    onError(PlaybackCommandError.scriptFailed(code: code, message: msg))
                }
            }
        }
    }

    nonisolated private static func readSpotifyNowPlaying() -> SpotifyPollResult {
        guard let app = SBApplication(bundleIdentifier: spotifyBundleId) else {
            return .notInstalled
        }
        // Bound the send so a wedged Spotify can never stall the poll loop.
        app.timeout = SpotifyPermission.sendTimeoutTicks
        guard app.isRunning else { return .notRunning }
        guard let track = app.value(forKey: "currentTrack") as? NSObject else {
            // A nil read is either TCC refusing the event or Spotify quitting
            // mid-poll; the AppleEvent error tells them apart.
            switch SpotifyPermission.classify(app.lastError()) {
            case .denied:
                SpotifyPermission.record(.denied)
                return .permissionDenied
            case .notDetermined:
                SpotifyPermission.record(.notDetermined)
                return .permissionNotDetermined
            default:
                return .notRunning
            }
        }
        SpotifyPermission.record(.granted)
        let id = (track.value(forKey: "id") as? String) ?? ""
        guard !id.isEmpty else { return .notRunning }
        let rawState = (app.value(forKey: "playerState") as? NSNumber)?.intValue
        let state: PlayerState
        switch rawState {
        case SpotifyScriptingPlayerState.playing.rawValue: state = .playing
        case SpotifyScriptingPlayerState.paused.rawValue: state = .paused
        default: state = .stopped
        }
        let artworkURL = (track.value(forKey: "artworkUrl") as? String) ?? ""
        return .running(NowPlaying(
            trackId: id,
            title: (track.value(forKey: "name") as? String) ?? "",
            artist: (track.value(forKey: "artist") as? String) ?? "",
            album: (track.value(forKey: "album") as? String) ?? "",
            durationSeconds: Double((track.value(forKey: "duration") as? NSNumber)?.doubleValue ?? 0) / 1_000.0,
            positionSeconds: (app.value(forKey: "playerPosition") as? NSNumber)?.doubleValue ?? 0,
            state: state,
            artworkURL: artworkURL.isEmpty ? nil : artworkURL
        ))
    }
}
