import XCTest
@testable import Cantio

/// `SpotifyPermission.classify` is the whole permission signal now that
/// `AEDeterminePermissionToAutomateTarget` is gone (it never returned against
/// Spotify, wedging the poll loop). Misreading these codes puts the app back
/// in the silent-failure state, so pin them.
final class SpotifyPermissionTests: XCTestCase {
    private func aeError(_ code: Int) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: code)
    }

    func test_classify_eventNotPermitted_returnsDenied() {
        XCTAssertEqual(SpotifyPermission.classify(aeError(-1743)), .denied)
    }

    func test_classify_wouldRequireUserConsent_returnsNotDetermined() {
        XCTAssertEqual(SpotifyPermission.classify(aeError(-1744)), .notDetermined)
    }

    /// A nil error means the read failed for a non-TCC reason — Spotify
    /// quitting mid-poll. Must not be reported as a permission problem, or the
    /// recovery alert fires every time the user closes Spotify.
    func test_classify_noError_returnsTargetNotRunning() {
        XCTAssertEqual(SpotifyPermission.classify(nil), .targetNotRunning)
    }

    func test_classify_unrelatedAppleEventError_returnsUnknown() {
        XCTAssertEqual(SpotifyPermission.classify(aeError(-1712)), .unknown)
    }

    func test_record_thenCheck_returnsRecordedState() {
        SpotifyPermission.record(.denied)
        XCTAssertEqual(SpotifyPermission.check(), .denied)

        SpotifyPermission.record(.granted)
        XCTAssertEqual(SpotifyPermission.check(), .granted)
    }

    /// `accessState()` gates on install/run before consulting TCC, so a
    /// recorded grant must not leak through when Spotify isn't there.
    func test_accessState_whenSpotifyNotRunning_neverReportsGranted() {
        SpotifyPermission.record(.granted)
        let running = !NSRunningApplication
            .runningApplications(withBundleIdentifier: SpotifyPermission.bundleId).isEmpty
        if !running {
            XCTAssertNotEqual(SpotifyPermission.accessState(), .granted)
        } else {
            XCTAssertEqual(SpotifyPermission.accessState(), .granted)
        }
    }
}
