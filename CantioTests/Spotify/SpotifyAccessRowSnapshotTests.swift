import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Cantio

/// The Permissions row is the only place a blocked Spotify grant is explained,
/// so its crowded states (two buttons + status + wrapping subtitle) are pinned
/// in both tones — the denied variant silently dropped its status word before.
@MainActor
final class SpotifyAccessRowSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Set to true ONLY when re-recording. Default false → tests verify diffs.
        // isRecording = true
    }

    /// Matches the real Settings content width (560 window − 28pt side padding
    /// − 14pt PrefRow padding), so truncation shows up here if it would ship.
    private let size = CGSize(width: 504, height: 64)

    private func row(_ state: SpotifyAccessState, scheme: ColorScheme) -> NSView {
        let palette = FL.palette(tone: scheme == .dark ? .dark : .light, hue: 220)
        let view = SpotifyAccessRow(palette: palette, initialState: state)
            .frame(width: size.width)
            .background(palette.bgElev)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    private func assertRow(_ state: SpotifyAccessState, _ scheme: ColorScheme,
                           file: StaticString = #file, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: row(state, scheme: scheme),
                       as: .image(precision: 0.99, perceptualPrecision: 0.96),
                       file: file, testName: testName, line: line)
    }

    func test_accessRow_denied_dark() { assertRow(.denied, .dark) }
    func test_accessRow_denied_light() { assertRow(.denied, .light) }
    func test_accessRow_granted_dark() { assertRow(.granted, .dark) }
    func test_accessRow_granted_light() { assertRow(.granted, .light) }
    func test_accessRow_undecided_dark() { assertRow(.undecided, .dark) }
    func test_accessRow_notRunning_dark() { assertRow(.notRunning, .dark) }
    func test_accessRow_notInstalled_dark() { assertRow(.notInstalled, .dark) }
}
