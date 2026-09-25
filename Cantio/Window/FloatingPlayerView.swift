import AppKit
import SwiftUI

/// Floating mini-player: now playing, scrubber, transport, shuffle/repeat,
/// volume, share, and a toggle for the lyrics window.
struct FloatingPlayerView: View {
    @ObservedObject var monitor: SpotifyMonitor
    @ObservedObject var prefs: Preferences

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static let panelSize = CGSize(width: 340, height: 200)
    /// Room around the panel for shadows; the window is this much larger on
    /// every side. `FloatingPlayerController` places by the panel. Sized for
    /// the glass, not our `.shadow`: while the window is key, glass casts its
    /// own shadow that measured ~0.25 alpha at the panel edge and ~28pt of
    /// falloff, which 16pt cut off in a hard rectangle.
    static let shadowSlack: CGFloat = 40
    static var windowSize: CGSize {
        CGSize(width: panelSize.width + shadowSlack * 2,
               height: panelSize.height + shadowSlack * 2)
    }

    private static let shape = MenuBarPanel.panelShape

    @State private var volumeDraft: Double?
    @State private var lastVolumeSend = Date.distantPast

    private enum Surface { case glass, material, solid }

    private var surface: Surface {
        if prefs.playerBackground == .black || reduceTransparency
            || colorSchemeContrast == .increased
        {
            return .solid
        }
        if #available(macOS 26, *) {
            return .glass
        }
        return .material
    }

    /// Always the dark palette. On black that is the only legible choice; on
    /// glass the system appearance says nothing about what is behind a
    /// floating window, so light text + halo is what holds over any backdrop
    /// (liquid-glass-macos §8).
    private var palette: FL.Palette {
        FL.palette(tone: .dark, hue: prefs.accentHue)
    }

    private var np: NowPlaying? {
        monitor.nowPlaying
    }

    private var available: Bool {
        monitor.availability == .available
    }

    var body: some View {
        panel
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
            .padding(Self.shadowSlack)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var panel: some View {
        if #available(macOS 26, *), surface == .glass {
            content
                .clipShape(Self.shape)
                .glassEffect(.regular, in: Self.shape)
                .overlay(Self.shape.strokeBorder(
                    MenuBarPanel.rimGradient(fade: 17 / Self.panelSize.height), lineWidth: 1
                ))
        } else {
            content
                .background(fill)
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(palette.borderStrong, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var fill: some View {
        if surface == .material {
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
        } else {
            FL.playerBlack
        }
    }

    private var content: some View {
        Group {
            switch monitor.availability {
            case .available: player
            case .notInstalled: emptyState("Install Spotify to use the player")
            case .notRunning: emptyState("Open Spotify to use the player")
            case .permissionDenied: permissionState
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .overlay(alignment: .topTrailing) { closeButton }
        .background(WindowDragArea())
    }

    private var closeButton: some View {
        TransportButton(symbol: "xmark", label: "Hide player", palette: palette,
                        disabled: false, primary: false, halo: onGlass) {
            prefs.playerVisible = false
        }
        .keyboardShortcut("w", modifiers: .command)
        // 10 + the button's 2pt ring inset = the panel's 12pt content inset.
        .padding(10)
    }

    private var onGlass: Bool { surface == .glass }
    private var increaseContrast: Bool { colorSchemeContrast == .increased }
    private var secondaryText: Color { increaseContrast ? palette.text : palette.textMuted }

    // MARK: - Player

    private var player: some View {
        VStack(spacing: 8) {
            header
            ScrubberRow(monitor: monitor, palette: palette)
                .modifier(Halo(on: onGlass))
            transport
            bottomRow
        }
        .padding(12)
        .background(volumeKeys)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AlbumArtView(hues: AlbumArtView.hues(for: np?.trackId), size: 56, artworkURL: np?.artworkURL,
                         ambientShadow: surface != .glass)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: np?.title ?? "Not playing",
                            font: .system(size: 13, weight: .semibold),
                            color: palette.text,
                            animated: np?.state == .playing)
                MarqueeText(text: np?.artist ?? "—",
                            font: .system(size: 11),
                            color: secondaryText,
                            animated: np?.state == .playing)
            }
            .modifier(Halo(on: onGlass))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(np.map { "Now playing: \($0.title) by \($0.artist)" } ?? "Not playing")
        }
        .padding(.trailing, 28)
        .padding(.bottom, 4)
    }

    private var transport: some View {
        let isPlaying = np?.state == .playing
        return HStack(spacing: 16) {
            ShuffleButton(monitor: monitor, palette: palette, halo: onGlass)
                .keyboardShortcut("s", modifiers: .command)

            TransportButton(symbol: "backward.end.fill", label: "Previous track", palette: palette,
                            disabled: !available, primary: false, halo: onGlass)
            {
                monitor.previousTrack()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill",
                            label: isPlaying ? "Pause" : "Play", palette: palette,
                            disabled: !available, primary: true)
            {
                monitor.playPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            TransportButton(symbol: "forward.end.fill", label: "Next track", palette: palette,
                            disabled: !available, primary: false, halo: onGlass)
            {
                monitor.nextTrack()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            RepeatButton(monitor: monitor, palette: palette, halo: onGlass)
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill", variableValue: displayedVolume / 100)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .modifier(Halo(on: onGlass))
                .frame(width: 18)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { displayedVolume },
                                  set: { volumeDraft = $0; sendVolume($0, force: false) }),
                   in: 0 ... 100,
                   onEditingChanged: { editing in
                       guard !editing, let v = volumeDraft else { return }
                       sendVolume(v, force: true)
                       releaseVolumeDraft(v)
                   })
                   .controlSize(.small)
                   .tint(palette.accent)
                   .frame(minHeight: 28)
                   .disabled(!available)
                   .accessibilityLabel("Volume")
                   .accessibilityValue("\(Int(displayedVolume.rounded())) percent")

            ShareTrackButton(nowPlaying: np, palette: palette, halo: onGlass)
                .keyboardShortcut("c", modifiers: [.command, .shift])

            TransportButton(symbol: "quote.bubble", label: "Lyrics window", palette: palette,
                            disabled: false, primary: false, on: prefs.windowVisible, halo: onGlass)
            {
                prefs.windowVisible.toggle()
            }
            .accessibilityValue(prefs.windowVisible ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
        }
    }

    // MARK: - Volume

    private var displayedVolume: Double {
        volumeDraft ?? Double(np?.volume ?? 100)
    }

    /// ⌘↑ / ⌘↓ nudge the volume while the window is key (Spotify's own keys;
    /// bare arrows stay with the slider). Zero-size, unfocusable buttons so
    /// the shortcuts ride the responder chain without adding Tab stops.
    private var volumeKeys: some View {
        ZStack {
            Button("") { nudgeVolume(10) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { nudgeVolume(-10) }.keyboardShortcut(.downArrow, modifiers: .command)
        }
        .focusable(false)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func nudgeVolume(_ delta: Double) {
        guard available else { return }
        let v = max(0, min(100, displayedVolume + delta))
        volumeDraft = v
        sendVolume(v, force: true)
        releaseVolumeDraft(v)
    }

    /// Every slider tick would queue its own AppleScript; send at most every
    /// 150 ms while dragging, plus the final value on release.
    private func sendVolume(_ v: Double, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastVolumeSend) >= 0.15 else { return }
        lastVolumeSend = now
        monitor.setVolume(Int(v.rounded()))
    }

    /// Hold the drafted value until the next poll has landed (~500 ms) so the
    /// slider does not snap back to the pre-change volume.
    private func releaseVolumeDraft(_ v: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if volumeDraft == v {
                volumeDraft = nil
            }
        }
    }

    // MARK: - Empty states

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(secondaryText)
            .multilineTextAlignment(.center)
            .padding(20)
    }

    private var permissionState: some View {
        VStack(spacing: 10) {
            Text("Cantio can’t read Spotify")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
            Button("Open System Settings") { SpotifyPermission.openSystemSettings() }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

}

/// `isMovableByWindowBackground` never fires over an `NSHostingView` (it
/// does not report `mouseDownCanMoveWindow`), so the panel background hands
/// its drags to AppKit itself. Controls in front still take their own clicks.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Legibility halo for text and glyphs on glass, at the dimmed-sibling weight
/// (liquid-glass-macos §8). Text and glyphs only: on fills or artwork it
/// would paint a dark layer over the material. The panel clips to the glass
/// shape, so it cannot leak past the edge.
struct Halo: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        } else {
            content
        }
    }
}
