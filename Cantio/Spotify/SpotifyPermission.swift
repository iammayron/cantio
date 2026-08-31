import AppKit
import Foundation
import ScriptingBridge

/// Tri-state result of querying TCC for AppleEvents automation permission to
/// drive Spotify.
///
/// macOS gates `tell application id "com.spotify.client"` behind the
/// "Automation" privacy section in System Settings. The app must:
/// 1. Declare `NSAppleEventsUsageDescription` in Info.plist (we do).
/// 2. Carry the `com.apple.security.automation.apple-events` entitlement
///    under hardened runtime (we do).
/// 3. Trigger the TCC consent prompt while Spotify is running, then either
///    proceed when granted or surface a recovery path when denied.
enum AutomationPermission: Equatable {
    /// User granted "Automation: Spotify" permission.
    case granted
    /// User denied permission, or it was revoked in System Settings.
    case denied
    /// Not yet decided. Calling `request()` will surface the consent prompt
    /// (Spotify must be running for the prompt to actually appear).
    case notDetermined
    /// Spotify isn't running, so we can't learn the decision. Treated as
    /// "unknown" — we'll re-check once Spotify is detected as running.
    case targetNotRunning
    /// Any other unexpected AppleEvent error.
    case unknown
}

/// Combined install / running / TCC state — what every recovery surface
/// (onboarding step, Settings section, the "lost access" alert) needs to show.
/// Install and run are checked first since TCC carries no decision for an app
/// that isn't present.
enum SpotifyAccessState: Equatable {
    case notInstalled
    case notRunning
    case undecided
    case denied
    case granted
}

/// Wraps the macOS Automation (AppleEvents) permission flow for Spotify.
///
/// `AEDeterminePermissionToAutomateTarget` is deliberately NOT used. It never
/// returns when Spotify fails to answer its probe event — observed on Spotify
/// 1.2.98 / macOS 26 — which wedged `SpotifyMonitor.poll()` on its first
/// iteration and left the app permanently stuck reporting "Spotify not
/// running", with no TCC traffic at all. Permission is instead inferred from
/// the AppleEvent error of a *real* read, bounded by `SBApplication.timeout`.
enum SpotifyPermission {
    /// Bundle id of the local Spotify desktop app.
    static let bundleId = "com.spotify.client"

    /// `errAEEventWouldRequireUserConsent` — TCC has no decision yet.
    /// `CoreServices` does not export this constant in Swift, so we declare it.
    private static let errAEEventWouldRequireUserConsent = -1_744

    /// Ticks (1/60 s). Caps how long a single AppleEvent read may block so a
    /// wedged Spotify can never stall the poll loop again.
    static let sendTimeoutTicks = 300 // 5 s

    private static let lock = NSLock()
    private static var cached: AutomationPermission = .targetNotRunning

    /// Last state observed from a real read. Non-blocking — safe on the main
    /// thread and from a SwiftUI refresh timer.
    static func check() -> AutomationPermission {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Records the state a real read just revealed. Called by `SpotifyMonitor`
    /// on every poll so `check()` stays current without issuing its own event.
    static func record(_ state: AutomationPermission) {
        lock.lock(); cached = state; lock.unlock()
    }

    /// Performs a minimal real read, which surfaces the system consent prompt
    /// when TCC has no decision yet. **Blocking** — call off the main thread.
    static func request() -> AutomationPermission {
        guard let app = SBApplication(bundleIdentifier: bundleId) else {
            record(.targetNotRunning)
            return .targetNotRunning
        }
        app.timeout = sendTimeoutTicks
        guard app.isRunning else {
            record(.targetNotRunning)
            return .targetNotRunning
        }
        let state = app.value(forKey: "playerState")
        let result = state != nil ? .granted : classify(app.lastError())
        record(result)
        return result
    }

    /// Maps the AppleEvent error left behind by a failed read onto a TCC
    /// decision. A nil error means the read failed for a non-permission
    /// reason (Spotify quitting mid-poll).
    static func classify(_ error: Error?) -> AutomationPermission {
        switch (error as NSError?)?.code {
        case Int(errAEEventNotPermitted): return .denied
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case nil: return .targetNotRunning
        default: return .unknown
        }
    }

    /// Clears Cantio's own Automation decision so macOS will prompt again.
    /// Once the user has denied, System Settings is the only other way back —
    /// and the Automation pane offers no way to re-add a missing app. Resetting
    /// our own bundle id needs no privileges. Returns whether `tccutil` exited
    /// cleanly; the caller re-asks on success.
    @discardableResult
    static func reset() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "AppleEvents", id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        guard task.terminationStatus == 0 else { return false }
        record(.notDetermined)
        return true
    }

    /// Snapshots the current connection state without surfacing a prompt.
    static func accessState() -> SpotifyAccessState {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) == nil { return .notInstalled }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty { return .notRunning }
        switch check() {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined, .targetNotRunning, .unknown: return .undecided
        }
    }

    /// Launches the Spotify desktop app.
    static func launchSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens System Settings → Privacy & Security → Automation so the user
    /// can grant or revoke permission. Falls back to the Privacy root if
    /// the deep link is unavailable.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }
}
