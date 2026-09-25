import XCTest
@testable import Cantio

final class ClampCenterTests: XCTestCase {
    // 1000×800 screen, Dock along the bottom (70pt), menu bar on top (25pt).
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let visible = NSRect(x: 0, y: 70, width: 1000, height: 705)
    private let size = NSSize(width: 372, height: 232)

    private func clamp(_ origin: NSPoint, inset: CGFloat? = 16) -> NSRect {
        FloatingLyricsWindow.clampCenter(NSRect(origin: origin, size: size),
                                         visible: visible, screen: screen,
                                         menuBarClearanceInset: inset)
    }

    func test_clampCenter_draggedOverDock_overhangsUpToHalf() {
        XCTAssertEqual(clamp(NSPoint(x: 300, y: -500)).midY, 70)
    }

    func test_clampCenter_draggedUnderMenuBar_staysBelowIt() {
        XCTAssertEqual(clamp(NSPoint(x: 300, y: 700)).maxY, 775 + 16)
    }

    func test_clampCenter_draggedPastSideEdge_overhangsUpToHalf() {
        XCTAssertEqual(clamp(NSPoint(x: -1000, y: 300)).midX, 0)
    }

    func test_clampCenter_noInset_centreMayReachMenuBar() {
        XCTAssertEqual(clamp(NSPoint(x: 300, y: 700), inset: nil).midY, 775)
    }
}
