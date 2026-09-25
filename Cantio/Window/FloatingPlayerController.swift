import AppKit
import Combine
import SwiftUI

/// Owns the floating player window. Fixed size, fully interactive (the whole
/// surface is controls, so no click-through), shown while `playerVisible`.
@MainActor
final class FloatingPlayerController {
    private let prefs: Preferences
    private let window: FloatingLyricsWindow
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?

    private static let autosaveName = "CantioFloatingPlayerWindow"

    init(monitor: SpotifyMonitor, prefs: Preferences) {
        self.prefs = prefs
        let size = FloatingPlayerView.windowSize
        window = FloatingLyricsWindow(contentRect: NSRect(origin: .zero, size: size))
        window.contentView = NSHostingView(rootView: FloatingPlayerView(monitor: monitor, prefs: prefs))
        window.contentMinSize = size
        window.contentMaxSize = size
        // Clamp only the centre, so up to half the player can be parked off a
        // screen edge (or over the Dock) while the other half stays reachable.
        // The menu bar still wins: nothing we own draws above it.
        window.clampCenterOnly = true
        window.menuBarClearanceInset = FloatingPlayerView.shadowSlack
        // Above the Dock, so it can be parked over it instead of behind it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // The panel draws its own rounded silhouette + shadow.
        window.hasShadow = false
        window.invalidateShadow()
        let restored = window.setFrameUsingName(Self.autosaveName)
        var frame = window.frame
        frame.size = size
        if !restored {
            frame.origin = Self.defaultOrigin(for: size)
        }
        // A saved position may be off-limits now (display unplugged, menu bar).
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: false)
        window.setFrameAutosaveName(Self.autosaveName)
    }

    func start() {
        prefs.$playerVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let window = self?.window else { return }
                if visible {
                    window.orderFrontRegardless()
                } else {
                    window.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // An `.accessory` app's borderless window does not take key on click,
        // so the in-window shortcuts (space, ⌘← / ⌘→, ↑ / ↓) would stay dead.
        // Activation lands asynchronously and hands key back to whichever
        // window last had it, so assert key again once it has.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let window = self?.window, event.window === window, !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
                DispatchQueue.main.async { window.makeKey() }
            }
            return event
        }
    }

    /// Bottom-right of the main screen, the *panel* (not the transparent
    /// shadow slack) 20pt in from the edges.
    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = 20 - FloatingPlayerView.shadowSlack
        return NSPoint(x: vf.maxX - size.width - inset, y: vf.minY + inset)
    }
}
