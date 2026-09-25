@testable import Cantio
import XCTest

final class ShareURLTests: XCTestCase {
    func test_shareURL_track_returnsOpenSpotify() {
        XCTAssertEqual(shareURL(for: "spotify:track:4uLU6hMCjMI75M1A2tKUQC"),
                       URL(string: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
    }

    func test_shareURL_episode_returnsOpenSpotify() {
        XCTAssertEqual(shareURL(for: "spotify:episode:abc123"),
                       URL(string: "https://open.spotify.com/episode/abc123"))
    }

    func test_shareURL_adOrLocalOrGarbage_returnsNil() {
        XCTAssertNil(shareURL(for: "spotify:ad:xyz"))
        XCTAssertNil(shareURL(for: "spotify:local:Artist:Album:Title:210"))
        XCTAssertNil(shareURL(for: "spotify:track:"))
        XCTAssertNil(shareURL(for: ""))
    }
}

@MainActor
final class PlayerCommandTests: XCTestCase {
    private func makeMonitor(_ availability: SpotifyAvailability = .available) -> SpotifyMonitor {
        let monitor = SpotifyMonitor()
        monitor._capturedScriptsForTesting = []
        monitor._setStateForTesting(availability: availability, nowPlaying: NowPlaying(
            trackId: "spotify:track:test", title: "T", artist: "A", album: "B",
            durationSeconds: 200, positionSeconds: 10, state: .playing,
            artworkURL: nil, shuffling: false, repeating: false, volume: 50
        ))
        return monitor
    }

    func test_setShuffling_whenAvailable_optimisticallyUpdatesAndSendsScript() {
        let monitor = makeMonitor()
        monitor.setShuffling(true)
        XCTAssertEqual(monitor.nowPlaying?.shuffling, true)
        XCTAssertTrue(monitor._capturedScriptsForTesting?.last?.contains("set shuffling to true") ?? false)
    }

    func test_setRepeating_whenAvailable_optimisticallyUpdatesAndSendsScript() {
        let monitor = makeMonitor()
        monitor.setRepeating(true)
        XCTAssertEqual(monitor.nowPlaying?.repeating, true)
        XCTAssertTrue(monitor._capturedScriptsForTesting?.last?.contains("set repeating to true") ?? false)
    }

    func test_setVolume_outOfRange_clampsTo0through100() {
        let monitor = makeMonitor()
        monitor.setVolume(140)
        XCTAssertEqual(monitor.nowPlaying?.volume, 100)
        XCTAssertTrue(monitor._capturedScriptsForTesting?.last?.contains("set sound volume to 100") ?? false)
        monitor.setVolume(-3)
        XCTAssertEqual(monitor.nowPlaying?.volume, 0)
    }

    func test_setVolume_whenNotAvailable_errorsWithoutMutating() {
        let monitor = makeMonitor(.notRunning)
        var captured: Error?
        monitor.setVolume(10) { captured = $0 }
        XCTAssertEqual(captured as? PlaybackCommandError, .notAvailable)
        XCTAssertEqual(monitor.nowPlaying?.volume, 50)
        XCTAssertEqual(monitor._capturedScriptsForTesting, [])
    }
}
