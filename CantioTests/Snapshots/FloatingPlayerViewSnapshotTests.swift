import AppKit
@testable import Cantio
import SnapshotTesting
import SwiftUI
import XCTest

/// Tone is not a dimension: the player always renders its dark palette.
/// Reduce Transparency / Increase Contrast take the same solid path as Black.
@MainActor
final class FloatingPlayerViewSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // isRecording = true
    }

    private func render(_ background: PlayerBackground, playing: Bool) -> NSView {
        let suite = "cantio.snapshot.player.\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        prefs.accentHue = 220
        prefs.playerBackground = background
        let monitor = SpotifyMonitor()
        if playing {
            monitor._setStateForTesting(availability: .available, nowPlaying: NowPlaying(
                trackId: "spotify:track:snapshot", title: "Song Title", artist: "Artist",
                album: "Album", durationSeconds: 200, positionSeconds: 60, state: .paused,
                artworkURL: nil, shuffling: true, repeating: false, volume: 70
            ))
        }
        let host = NSHostingView(rootView: FloatingPlayerView(monitor: monitor, prefs: prefs))
        host.frame = CGRect(origin: .zero, size: FloatingPlayerView.windowSize)
        return host
    }

    private let strategy = Snapshotting<NSView, NSImage>.image(precision: 0.99, perceptualPrecision: 0.96)

    func test_floatingPlayer_black_playing() {
        assertSnapshot(of: render(.black, playing: true), as: strategy)
    }

    func test_floatingPlayer_black_notRunning() {
        assertSnapshot(of: render(.black, playing: false), as: strategy)
    }

    func test_floatingPlayer_glass_playing() {
        assertSnapshot(of: render(.glass, playing: true), as: strategy)
    }

    func test_floatingPlayer_glass_notRunning() {
        assertSnapshot(of: render(.glass, playing: false), as: strategy)
    }
}
