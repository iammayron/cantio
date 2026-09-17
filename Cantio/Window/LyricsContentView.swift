import SwiftUI
import AppKit

/// Shared bridge between the SwiftUI capsule geometry and the AppKit window's
/// hit-testing. The pill window stays the same fixed 520x80 NSWindow but the
/// visible capsule hugs its content, leaving transparent margins. The view
/// publishes the capsule's frame (in the SwiftUI host's content coordinate
/// space — top-left origin) and the controller flips `ignoresMouseEvents`
/// based on whether the cursor is inside that rect.
@MainActor
final class PillHitTarget: ObservableObject {
    @Published var capsuleRectInContentView: CGRect = .zero
    /// True while the user is dragging the pill. The view freezes to a
    /// fixed-size placeholder capsule so the silhouette is a stable
    /// alignment target instead of flickering with live lyric width.
    @Published var isDragging: Bool = false
}

/// Floating lyrics window content. Two styles: pill (capsule overlay) and
/// fullscreen (karaoke backdrop).
struct LyricsContentView: View {
    @ObservedObject var monitor: SpotifyMonitor
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var prefs: Preferences
    @EnvironmentObject var hitTarget: PillHitTarget
    @StateObject private var artColors = ArtworkColors()

    /// Coordinate space declared at the root of `pillBody` so PillCapsule
    /// can report its frame relative to the NSHostingView's contentView.
    private static let pillCoordinateSpace = "pillContent"

    /// Upper bound on pill-line width: the active screen's visible width minus
    /// a side margin. A line shorter than this renders on one line at full
    /// size; a longer one *wraps* (never shrinks). The window grows from its
    /// center to fit the line up to this screen bound (see
    /// `FloatingLyricsController.resizePillToContent`).
    private var pillContentMaxWidth: CGFloat {
        let visible = NSScreen.main?.visibleFrame.width ?? 1440
        // 70% of the screen: wide enough that virtually every lyric fits on
        // one line, while leaving horizontal slack so a grown pill isn't
        // clamped to screen-center on release (which read as a "pull back").
        return max(360, visible * 0.7)
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    /// Fullscreen chrome (header + transport + exit) auto-hides ~3s after the
    /// last pointer movement so the lyrics read clean. Kept visible whenever
    /// VoiceOver is on so the controls never vanish from the a11y tree.
    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?

    private var style: WindowStyle { prefs.windowStyle }
    private var bgStyle: BackgroundStyle { prefs.backgroundStyle }
    private var resolvedTone: FL.Tone { colorScheme == .dark ? .dark : .light }
    private var palette: FL.Palette {
        FL.palette(tone: effectiveTone, hue: prefs.accentHue)
    }
    private var effectiveTone: FL.Tone { resolvedTone }
    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    /// Effective glass style for the pill. Honors accessibility:
    /// Reduce Transparency + Increase Contrast both force `.off` so the
    /// silhouette is solid and high-contrast against the wallpaper.
    private var pillGlassStyle: GlassStyle {
        if reduceTransparency || increaseContrast { return .off }
        return prefs.effectiveGlassStyle
    }

    /// Maps `prefs.linesVisible` (1 / 3 / 5) to the symmetric neighbor count
    /// shown around the current line: 0 / 1 / 2.
    private var linesAroundFromPref: Int {
        let v = prefs.linesVisible
        if v <= 1 { return 0 }
        if v <= 3 { return 1 }
        return 2
    }

    var body: some View {
        Group {
            switch style {
            case .floating: pillBody(linesAround: linesAroundFromPref)
            case .fullscreen: fullscreenBody
            }
        }
        .onAppear { syncArtColors() }
        .onChange(of: monitor.nowPlaying?.trackId) { _, _ in syncArtColors() }
    }

    private func syncArtColors() {
        artColors.update(trackId: monitor.nowPlaying?.trackId,
                         artworkURL: monitor.nowPlaying?.artworkURL)
    }

    // MARK: - Pill / Pill Stack

    @ViewBuilder
    private func pillBody(linesAround: Int) -> some View {
        ZStack {
            // No window chrome — capsule(s) hover over wallpaper.
            if hitTarget.isDragging {
                dragPlaceholder
            } else {
            switch monitor.availability {
            case .permissionDenied:
                permissionCapsule.modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
            case .notInstalled:
                placeholderCapsule("Install Spotify to see lyrics")
                    .modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
            case .notRunning:
                if monitor.permission == .notDetermined || monitor.permission == .unknown {
                    permissionCapsule.modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
                } else {
                    placeholderCapsule("Open Spotify to see lyrics")
                        .modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
                }
            case .available:
                if monitor.nowPlaying == nil || monitor.nowPlaying?.state == .stopped {
                    placeholderCapsule("Play a song in Spotify")
                        .modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
                } else {
                    lyricsContent(forPill: true, linesAround: linesAround)
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.pillCoordinateSpace)
    }

    /// Fixed-size pill shown while dragging. Its footprint equals `DragPill`,
    /// so the guide rulers hug it exactly regardless of the playing lyric.
    @ViewBuilder
    private var dragPlaceholder: some View {
        let s = DragPill.size(activeFontSize: prefs.fontSize.activeSize)
        let fs = prefs.fontSize.activeSize
        let label = Text(DragPill.text)
            .font(.system(size: fs, weight: .semibold))
            .tracking(max(0.4, fs * 0.04))
            .foregroundStyle(palette.accent)
            .frame(width: s.width, height: s.height)
        if #available(macOS 26, *), pillGlassStyle != .off {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label.background {
                Capsule().fill(palette.bgElev)
                    .overlay(Capsule().strokeBorder(palette.borderStrong, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
            }
        }
    }

    // MARK: - Fullscreen karaoke

    @ViewBuilder
    private var fullscreenBody: some View {
        ZStack(alignment: .topTrailing) {
            KaraokeBackdrop(hues: trackHues, tone: effectiveTone,
                            palette: palette, reduceMotion: reduceMotion)
            // Top + bottom scrims so the white chrome clears AA contrast even
            // over a bright album-art backdrop. Fades with the chrome.
            chromeScrim
                .modifier(ChromeFade(visible: chromeVisible, reduceMotion: reduceMotion))
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                // Header — album art + title.
                if let np = monitor.nowPlaying {
                    HStack(spacing: 22) {
                        AlbumArtView(hues: trackHues, size: 96, artworkURL: np.artworkURL)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(np.title)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 1)
                            Text("\(np.artist) · \(np.album)")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.74))
                                .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                        }
                        Spacer()
                    }
                    .padding(.top, 44)
                    .padding(.horizontal, 48)
                    // Read as one VoiceOver element; art is decorative.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(np.title), \(np.artist), \(np.album)")
                    .modifier(ChromeFade(visible: chromeVisible, reduceMotion: reduceMotion))
                }
                Spacer(minLength: 0)
                // Fullscreen ignores prefs.fontSize and auto-scales to fill
                // — a 27" external and a 13" laptop both want different
                // absolute sizes, and the user shouldn't have to retune the
                // font slider when they plug in a display.
                GeometryReader { geo in
                    let active = min(96, max(28, geo.size.height / 8))
                    lyricsContent(forPill: false, linesAround: linesAroundFromPref,
                                  fullscreenActiveSize: active)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(.horizontal, 80)
                Spacer(minLength: 0)
                if monitor.nowPlaying != nil {
                    FullscreenTransport(monitor: monitor, onInteract: revealChrome)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 48)
                        .modifier(ChromeFade(visible: chromeVisible, reduceMotion: reduceMotion))
                }
            }
            // Visible exit affordance — Esc also works (controller's local
            // key monitor) but a discoverable button matches HIG.
            Button {
                prefs.windowStyle = .floating
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Exit fullscreen")
            .accessibilityLabel("Exit fullscreen")
            .padding(.top, 24)
            .padding(.trailing, 24)
            .modifier(ChromeFade(visible: chromeVisible, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Esc exits — bound to the root so it works even when the exit button's
        // chrome has auto-hidden (its own keyboardShortcut goes inert then).
        // Backstops the controller's local key monitor, which only fires while
        // the borderless window holds key focus.
        .onExitCommand { prefs.windowStyle = .floating }
        // Symmetric with the pill's double-click-to-enter: double-click empty
        // backdrop to drop back to the floating pill. Transport buttons /
        // scrubber consume their own taps first, so this only fires on the
        // backdrop.
        .onTapGesture(count: 2) { prefs.windowStyle = .floating }
        // Pointer movement reveals the chrome and restarts the idle countdown.
        .onContinuousHover { phase in
            if case .active = phase { revealChrome() }
        }
        .onAppear { revealChrome() }
        .onDisappear { chromeHideTask?.cancel(); chromeHideTask = nil }
    }

    /// Dark gradient behind the top header and bottom transport so white
    /// chrome text/controls keep AA contrast over a bright album-art backdrop.
    private var chromeScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    /// Show the chrome and (unless VoiceOver is active) schedule it to hide
    /// after a short idle period.
    private func revealChrome() {
        chromeHideTask?.cancel()
        if !chromeVisible { chromeVisible = true }
        guard !voiceOverEnabled else { return }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }

    // MARK: - Lyrics renderer

    @ViewBuilder
    private func lyricsContent(forPill: Bool, linesAround: Int,
                               fullscreenActiveSize: CGFloat? = nil) -> some View {
        switch lyrics.state {
        // Floating window stays quiet for transient / empty states — the
        // menubar panel surfaces "No lyrics found" / errors instead.
        case .idle, .loading, .notFound: EmptyView()
        case .error(let msg): placeholderCapsuleOrText(msg, forPill: forPill)
        case .synced(let lines):
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                let pos = monitor.interpolatedPosition(now: ctx.date)
                    ?? monitor.nowPlaying?.positionSeconds ?? 0
                let lp = LyricPosition.compute(lines: lines, position: pos)
                syncedRender(lp: lp, forPill: forPill, linesAround: linesAround,
                             fullscreenActiveSize: fullscreenActiveSize)
                    // Pill swaps lines instantly: the capsule + window resize
                    // per line, and animating that geometry made the siblings
                    // visibly slide across the screen. Fullscreen keeps the
                    // crossfade (fixed-size, no resize). Reduce Motion: hard-cut.
                    .animation(reduceMotion || forPill ? nil : .easeInOut(duration: 0.3),
                               value: lp.current?.timestamp)
            }
        }
    }

    @ViewBuilder
    private func syncedRender(lp: LyricPosition, forPill: Bool,
                              linesAround: Int,
                              fullscreenActiveSize: CGFloat? = nil) -> some View {
        let cur = lp.current
        let large = fullscreenActiveSize != nil
        let activeSize: CGFloat = fullscreenActiveSize ?? prefs.fontSize.activeSize
        let dimSize: CGFloat = large
            ? max(18, activeSize * 0.6)
            : max(12, prefs.fontSize.activeSize * 0.78)
        let curWords = cur?.words ?? (forPill ? ["♪"] : ["♪  ♪  ♪"])

        if forPill {
            // Pill sibling sizes scale with the active line so the user's
            // FontSize choice carries through to the whole pill, not just
            // the capsule.
            let pillActive = prefs.fontSize.activeSize
            let pillFar: CGFloat = max(10, pillActive * 0.55)
            let pillNear: CGFloat = max(11, pillActive * 0.7)
            // Spacing bumped from 8 → 16 so dim sibling lines sit outside
            // the pill's shadow falloff (~6pt). Within that band, sibling
            // crossfades read as a "pulsing dark edge" along the pill rim.
            VStack(spacing: 14) {
                if linesAround >= 2 {
                    pillSibling(words: lp.prev2?.words, exists: lp.prev2 != nil,
                                size: pillFar, opacity: 0.6)
                }
                if linesAround >= 1 {
                    pillSibling(words: lp.prev?.words, exists: lp.prev != nil,
                                size: pillNear, opacity: 1)
                }
                PillCapsule(words: curWords, palette: palette, tone: effectiveTone,
                            bgStyle: bgStyle, fontSize: pillActive,
                            glassStyle: pillGlassStyle, increaseContrast: increaseContrast,
                            reduceTransparency: reduceTransparency)
                    .modifier(PillCapsuleFrameReporter(space: Self.pillCoordinateSpace, hitTarget: hitTarget))
                if linesAround >= 1 {
                    pillSibling(words: lp.next?.words, exists: lp.next != nil,
                                size: pillNear, opacity: 1)
                }
                if linesAround >= 2 {
                    pillSibling(words: lp.next2?.words, exists: lp.next2 != nil,
                                size: pillFar, opacity: 0.6)
                }
            }
            .frame(maxWidth: pillContentMaxWidth)
            .help("Double-click for fullscreen")
        } else {
            VStack(spacing: large ? 26 : 10) {
                if linesAround >= 2 {
                    windowSibling(words: lp.prev2?.words, exists: lp.prev2 != nil,
                                  size: dimSize * 0.85, fade: 0.5)
                }
                if linesAround >= 1 {
                    windowSibling(words: lp.prev?.words, exists: lp.prev != nil,
                                  size: dimSize, fade: 1, highlighted: true)
                }
                LyricLineView(words: curWords, highlighted: true,
                              active: true, dim: false, color: palette.text,
                              accent: palette.accent, size: activeSize)
                if linesAround >= 1 {
                    windowSibling(words: lp.next?.words, exists: lp.next != nil,
                                  size: dimSize, fade: 1)
                }
                if linesAround >= 2 {
                    windowSibling(words: lp.next2?.words, exists: lp.next2 != nil,
                                  size: dimSize * 0.85, fade: 0.5)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func pillSibling(words: [String]?, exists: Bool,
                             size: CGFloat, opacity: Double) -> some View {
        // Plain wrapped Text (not `LyricLineView`, which wraps each word
        // independently and would produce per-word "..." on overflow).
        // Bounded by the parent's screen-width max; wraps past it.
        // Sibling lines are blurred so attention stays on the active line.
        Text(words?.joined(separator: " ") ?? "♪")
            .font(.system(size: size, weight: .semibold))
            .tracking(max(0.3, size * 0.04))
            .foregroundStyle(palette.textFaint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .blur(radius: 1.5)
            // Same halo, inactive values. Siblings float free of any capsule,
            // so nothing to clip against. After the blur, so the halo is not
            // itself blurred.
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            .opacity(exists ? opacity : 0)
            // Instant: the pill window resizes per line, and animating the
            // siblings' reflow made them visibly slide across the screen.
            .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func windowSibling(words: [String]?, exists: Bool,
                               size: CGFloat, fade: Double,
                               highlighted: Bool = false) -> some View {
        // Sibling lines are blurred so attention stays on the active line.
        LyricLineView(words: words ?? ["♪"],
                      highlighted: highlighted,
                      active: false, dim: true, color: palette.textFaint,
                      accent: palette.accent, size: size)
            .opacity(exists ? fade : 0)
            .blur(radius: 2)
    }

    // MARK: - Permission capsule

    private var permissionCapsule: some View {
        Button {
            SpotifyPermission.openSystemSettings()
        } label: {
            PillCapsule(words: ["Grant", "Spotify", "access"],
                        palette: palette, tone: effectiveTone,
                        bgStyle: bgStyle, fontSize: prefs.fontSize.activeSize,
                        glassStyle: pillGlassStyle, increaseContrast: increaseContrast,
                        reduceTransparency: reduceTransparency)
        }
        .buttonStyle(.plain)
        .help("Open Automation settings")
        .accessibilityLabel("Open Spotify access settings")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: prefs.fontSize.bodySize, weight: .medium))
            .foregroundStyle(palette.textMuted)
            .frame(maxWidth: .infinity)
    }

    private func placeholderCapsule(_ text: String) -> some View {
        let words = text.split(separator: " ").map(String.init)
        return PillCapsule(words: words,
                           palette: palette, tone: effectiveTone,
                           bgStyle: bgStyle, fontSize: prefs.fontSize.activeSize,
                           glassStyle: pillGlassStyle, increaseContrast: increaseContrast,
                           reduceTransparency: reduceTransparency)
    }

    @ViewBuilder
    private func placeholderCapsuleOrText(_ text: String, forPill: Bool) -> some View {
        if forPill { placeholderCapsule(text) } else { placeholder(text) }
    }

    // MARK: - Helpers

    /// Album-art-derived hues when extraction succeeded, else a deterministic
    /// hash of the track id so identity still reads before/without artwork.
    private var trackHues: [Double] { artColors.hues ?? hashHues }

    private var hashHues: [Double] {
        let seed = monitor.nowPlaying?.trackId ?? "cantio"
        var hash = UInt64(5381)
        for ch in seed.unicodeScalars { hash = hash &* 33 &+ UInt64(ch.value) }
        let h0 = Double(hash % 360)
        return [h0, (h0 + 56).truncatingRemainder(dividingBy: 360),
                (h0 + 110).truncatingRemainder(dividingBy: 360)]
    }
}

// MARK: - Lyric position (replaces old activeIndex)

struct LyricPosition {
    struct Line { let timestamp: Double; let text: String; let words: [String] }
    let prev2: Line?
    let prev: Line?
    let current: Line?
    let next: Line?
    let next2: Line?

    static func compute(lines: [LyricLine], position: Double) -> LyricPosition {
        guard !lines.isEmpty else {
            return LyricPosition(prev2: nil, prev: nil, current: nil, next: nil, next2: nil)
        }
        let idx = LyricLine.activeIndex(in: lines, at: position)
        guard let i = idx else {
            return LyricPosition(prev2: nil, prev: nil, current: nil,
                next: line(at: 0, in: lines),
                next2: lines.count > 1 ? line(at: 1, in: lines) : nil)
        }
        let cur = line(at: i, in: lines)
        let prev = i > 0 ? line(at: i - 1, in: lines) : nil
        let prev2 = i > 1 ? line(at: i - 2, in: lines) : nil
        let nxt = i + 1 < lines.count ? line(at: i + 1, in: lines) : nil
        let nxt2 = i + 2 < lines.count ? line(at: i + 2, in: lines) : nil
        return LyricPosition(prev2: prev2, prev: prev, current: cur, next: nxt, next2: nxt2)
    }

    private static func line(at i: Int, in lines: [LyricLine]) -> Line {
        let l = lines[i]
        let text = l.text.isEmpty ? "♪" : l.text
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return Line(timestamp: l.timestamp, text: text,
                    words: words.isEmpty ? ["♪"] : words)
    }
}

// MARK: - Lyric line renderer

struct LyricLineView: View {
    let words: [String]
    let highlighted: Bool
    let active: Bool
    let dim: Bool
    let color: Color
    let accent: Color
    let size: CGFloat

    var body: some View {
        let opacity: Double = active ? 1 : (dim ? 0.4 : 0.6)
        FlowLayout(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                Text(w)
                    .font(.system(size: size, weight: active ? .bold : .semibold))
                    .tracking(max(0.3, size * 0.04))
                    .foregroundStyle(highlighted ? accent : color.opacity(0.55))
                    .fixedSize()
            }
        }
        .opacity(opacity)
        // Legibility halo: a tight dark edge + a softer spread so the line
        // stays readable even when the album-art backdrop drifts to the same
        // hue as the text. Only the active line carries the full weight; dim
        // siblings get a lighter shadow so the halos don't stack into murk.
        .shadow(color: .black.opacity(active ? 0.6 : 0.35), radius: active ? 3 : 2, y: 1)
        .shadow(color: .black.opacity(active ? 0.4 : 0.22), radius: active ? 14 : 8, y: 2)
    }
}

// MARK: - Pill capsule

struct PillCapsule: View {
    let words: [String]
    let palette: FL.Palette
    let tone: FL.Tone
    let bgStyle: BackgroundStyle
    /// Active-line font size driven by `Preferences.FontSize`. Defaults to
    /// the legacy hard-coded 16 so existing tests / call sites that don't
    /// pass a size still render at the previous default.
    var fontSize: CGFloat = 16
    /// Liquid Glass style. `.off` keeps the existing solid/visual-effect
    /// rendering. Caller is expected to have already collapsed accessibility
    /// states (Reduce Transparency / Increase Contrast) into this value.
    var glassStyle: GlassStyle = .off
    var increaseContrast: Bool = false
    /// Reduce Transparency forces the legacy fill to fully opaque palette
    /// elev so the pill silhouette doesn't bleed wallpaper through. Caller
    /// passes the env value directly — keeps PillCapsule a pure View.
    var reduceTransparency: Bool = false

    var body: some View {
        // Single glass surface — no `GlassEffectContainer`. The container
        // exists to merge/morph *multiple* glass shapes; around one shape it
        // is a no-op that can suppress the edge lensing the system paints on
        // the boundary. The pill's siblings are plain text, not glass.
        if #available(macOS 26, *), glassStyle != .off {
            pillContent
                .glassEffect(.regular, in: Capsule())
                // `.glassEffect()` casts no shadow of its own on a hosted
                // window (measured on the tray panel, see `MenuBarPanel.body`),
                // and `FloatingLyricsController.applyWindowChrome` keeps
                // `NSWindow.hasShadow` off — a rectangular window shadow under
                // a capsule halos the silhouette. So the capsule lifts off the
                // wallpaper only if SwiftUI draws it, same values as the panel.
                .shadow(color: .black.opacity(0.10), radius: 18, y: 2)
                .transaction { $0.animation = nil }
        } else {
            pillContent
                .background { legacyBackground }
                .transaction { $0.animation = nil }
        }
    }

    private var pillContent: some View {
        // Capsule hugs the rendered text so short lines stay tight; a long
        // line is bounded by the parent's screen-width max and wraps onto
        // additional lines instead of truncating. `.fixedSize(horizontal:
        // false, vertical: true)` keeps the width flexible (no unbounded
        // intrinsic width that would let the window run away) while letting
        // wrapped lines grow the height.
        Text(words.joined(separator: " "))
            .font(.system(size: fontSize, weight: .semibold))
            .tracking(max(0.4, fontSize * 0.04))
            .foregroundStyle(palette.accent)
            // Wrap (don't truncate or shrink): with no line limit, the Text
            // hugs its intrinsic width when short and wraps only when it would
            // exceed the parent's screen-width max. The window grows to fit.
            .multilineTextAlignment(.center)
            // Legibility halo. The glass adopts whatever is behind the window,
            // so over a bright backdrop the capsule goes pale and the accent
            // text has nothing to sit against. Same values as
            // `LyricLineView`'s active line.
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
            .padding(.horizontal, max(12, fontSize * 0.9))
            .padding(.vertical, max(7, fontSize * 0.5))
            // Load-bearing, not cosmetic: a radius-12 halo leaks well past the
            // 7pt vertical padding, and `PillCapsuleShadowLeakTests` asserts
            // the rows above the capsule darken by no more than 0.20. Clipping
            // to the same capsule the glass uses contains it.
            .clipShape(Capsule())
    }

    private var legacyBackground: some View {
        let stroke = tone == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        return Capsule()
            .fill(pillFillColor)
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            // drawingGroup rasterizes the capsule + shadow into a single
            // bitmap, preventing CALayer's implicit shadowPath animation
            // when the HStack's intrinsic width changes between word
            // counts (which produced the residual bottom band even with
            // compositingGroup + animation suppression).
            .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 4, y: 0)
            .drawingGroup()
    }

    private var pillFillColor: Color {
        // Reduce Transparency / Increase Contrast force fully opaque palette
        // so the silhouette is legible against any wallpaper. Without this
        // the legacy glass fill stays translucent (0.58–0.92 alpha) even
        // after pillGlassStyle collapses to .off.
        if increaseContrast || reduceTransparency { return palette.bgElev }
        switch bgStyle {
        case .solid:
            return tone == .dark
                ? Color(.sRGB, red: 22/255, green: 24/255, blue: 30/255, opacity: 0.92)
                : Color(.sRGB, red: 252/255, green: 252/255, blue: 254/255, opacity: 0.94)
        case .glass:
            // Legacy fallback fill (pre-macOS-26 / `.off` glass style). Uses
            // a fixed mid-translucency now that the user-controlled tint
            // strength has been removed.
            let glassOp = 0.75
            return tone == .dark
                ? Color(.sRGB, red: 22/255, green: 24/255, blue: 30/255, opacity: glassOp)
                : Color(.sRGB, red: 252/255, green: 252/255, blue: 254/255, opacity: glassOp)
        }
    }
}

// MARK: - Track strip

struct TrackStrip: View {
    let track: NowPlaying
    let palette: FL.Palette
    let hues: [Double]

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(hues: hues, size: 40, artworkURL: track.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            NowBars(color: palette.accent)
        }
    }
}

// MARK: - Album art (procedural)

struct AlbumArtView: View {
    let hues: [Double]
    let size: CGFloat
    var artworkURL: String? = nil
    /// Wide ambient shadow. Off when the tile sits on a Liquid Glass surface:
    /// WWDC25 session 323 — "if your app has any extra backgrounds or darkening
    /// effects behind the bar items, make sure to remove them, as these will
    /// interfere with the effect." The tight contact shadow stays either way.
    var ambientShadow: Bool = true

    var body: some View {
        ZStack {
            procedural
            if let s = artworkURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .transition(.opacity.animation(.easeOut(duration: 0.25)))
                    default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        .shadow(color: .black.opacity(ambientShadow ? 0.18 : 0), radius: 14, y: 4)
        // Purely decorative — the song title/artist text carries the label.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var procedural: some View {
        // HSB-based gradient: avoids OKLCH gamut clipping that can render
        // certain hues nearly black, and provides a guaranteed-visible base
        // color when RadialGradients don't fully cover the frame.
        let h0 = hues[0] / 360
        let h1 = hues[1] / 360
        let h2 = hues[2] / 360
        let base = Color(hue: h2, saturation: 0.55, brightness: 0.22)
        ZStack {
            base
            RadialGradient(colors: [
                Color(hue: h0, saturation: 0.72, brightness: 0.95),
                Color(hue: h1, saturation: 0.65, brightness: 0.55),
                base.opacity(0)
            ], center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: size)
            RadialGradient(colors: [
                Color(hue: h2, saturation: 0.65, brightness: 0.78).opacity(0.7),
                .clear
            ], center: UnitPoint(x: 0.85, y: 0.85), startRadius: 0, endRadius: size * 0.7)
        }
    }
}

// MARK: - Now-playing bars

struct NowBars: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * 3 + Double(i) * 0.7) * 0.5 + 0.5
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: size * (0.3 + 0.7 * phase))
                }
            }
            .frame(height: size)
        }
    }
}

// MARK: - Karaoke fullscreen backdrop

struct KaraokeBackdrop: View {
    let hues: [Double]
    let tone: FL.Tone
    let palette: FL.Palette
    let reduceMotion: Bool

    /// Base luminance flips with tone — dark = deep ambient depth, light =
    /// airy palette-derived backdrop. Both keep the chromatic blooms tinted
    /// by the track hues so identity reads at a glance.
    private var baseLuminance: Double { tone == .dark ? 0.16 : 0.94 }
    private var bloomALuminance: Double { tone == .dark ? 0.55 : 0.78 }
    private var bloomBLuminance: Double { tone == .dark ? 0.50 : 0.72 }
    private var vignetteOpacity: Double { tone == .dark ? 0.45 : 0.18 }
    private var vignetteTopOpacity: Double { tone == .dark ? 0.25 : 0.10 }

    /// Soft blobs that drift on slow, independent sine paths so the backdrop
    /// breathes without distracting from the lyrics. Positions / amplitudes are
    /// fractions of the live screen so it scales from a laptop to a 27" display.
    private struct Bubble {
        let cx: Double, cy: Double      // base center, fraction of (w, h)
        let size: Double                // diameter, fraction of min(w, h)
        let hueIndex: Int
        let bright: Bool                // pick bloomA (true) vs bloomB luminance
        let ampX: Double, ampY: Double  // drift amplitude, fraction of (w, h)
        let speedX: Double, speedY: Double, speedPulse: Double
        let phase: Double, blur: Double
    }

    private static let bubbles: [Bubble] = [
        Bubble(cx: 0.24, cy: 0.30, size: 0.95, hueIndex: 0, bright: true,
               ampX: 0.11, ampY: 0.13, speedX: 0.42, speedY: 0.33, speedPulse: 0.55, phase: 0.0, blur: 55),
        Bubble(cx: 0.74, cy: 0.24, size: 0.78, hueIndex: 1, bright: false,
               ampX: 0.13, ampY: 0.10, speedX: 0.31, speedY: 0.46, speedPulse: 0.48, phase: 1.7, blur: 62),
        Bubble(cx: 0.60, cy: 0.72, size: 1.05, hueIndex: 2, bright: true,
               ampX: 0.10, ampY: 0.11, speedX: 0.38, speedY: 0.28, speedPulse: 0.60, phase: 3.1, blur: 70),
        Bubble(cx: 0.32, cy: 0.78, size: 0.66, hueIndex: 1, bright: false,
               ampX: 0.14, ampY: 0.12, speedX: 0.27, speedY: 0.40, speedPulse: 0.52, phase: 4.5, blur: 58),
        Bubble(cx: 0.86, cy: 0.62, size: 0.72, hueIndex: 0, bright: true,
               ampX: 0.11, ampY: 0.14, speedX: 0.35, speedY: 0.24, speedPulse: 0.50, phase: 5.9, blur: 64),
    ]

    var body: some View {
        if reduceMotion {
            // Reduce Motion: freeze every bubble at t = 0 — no drift, no pulse.
            GeometryReader { geo in bubbleField(geo: geo, t: 0, animate: false) }
                .compositingGroup()
                .clipped()
        } else {
            TimelineView(.animation) { ctx in
                GeometryReader { geo in
                    bubbleField(geo: geo, t: ctx.date.timeIntervalSinceReferenceDate, animate: true)
                }
                .compositingGroup()
                .clipped()
            }
        }
    }

    private func bubbleField(geo: GeometryProxy, t: TimeInterval, animate: Bool) -> some View {
        let w = geo.size.width, h = geo.size.height
        let m = min(w, h)
        return ZStack {
            FL.oklch(baseLuminance, 0.02, hues[2])
            ForEach(Array(Self.bubbles.enumerated()), id: \.offset) { _, b in
                let hue = hues[b.hueIndex % hues.count]
                let lum = b.bright ? bloomALuminance : bloomBLuminance
                let dx = animate ? sin(t * b.speedX + b.phase) * (w * b.ampX) : 0
                let dy = animate ? cos(t * b.speedY + b.phase) * (h * b.ampY) : 0
                let pulse = animate ? 1 + 0.12 * sin(t * b.speedPulse + b.phase) : 1
                let d = b.size * m
                Circle()
                    .fill(RadialGradient(colors: [FL.oklch(lum, 0.18, hue), .clear],
                          center: .center, startRadius: 0, endRadius: d / 2))
                    .frame(width: d, height: d)
                    .scaleEffect(pulse)
                    .position(x: w * b.cx + dx, y: h * b.cy + dy)
                    .blur(radius: b.blur)
            }
            vignette
        }
    }

    private var vignette: some View {
        // Light tone uses subtle dark edges; dark tone keeps stronger
        // bottom-heavy depth for foreground contrast.
        LinearGradient(stops: [
            .init(color: .black.opacity(vignetteTopOpacity), location: 0),
            .init(color: .clear, location: 0.3),
            .init(color: .clear, location: 0.7),
            .init(color: .black.opacity(vignetteOpacity), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Fullscreen chrome fade

/// Fades + disables hit-testing for auto-hiding fullscreen chrome. Reduce
/// Motion still fades (opacity only, no movement) so the controls don't
/// pop in/out abruptly.
private struct ChromeFade: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            // Drop hidden chrome from the AX tree so VoiceOver / Tab can't land
            // on an invisible, non-actionable control (dead focus stop).
            .accessibilityHidden(!visible)
            .animation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.22),
                       value: visible)
    }
}

// MARK: - Fullscreen transport

/// Centered scrubber + transport cluster for the fullscreen overlay. Reuses
/// `SpotifyMonitor`'s optimistic commands (`playPause` / `previousTrack` /
/// `nextTrack` / `seek`). Styled white-on-glass for the dark karaoke backdrop
/// rather than the menu panel's palette-tinted look.
struct FullscreenTransport: View {
    @ObservedObject var monitor: SpotifyMonitor
    /// Called on any transport interaction (pointer or keyboard shortcut) so
    /// the auto-hiding chrome reveals itself and restarts its idle countdown —
    /// this is what keeps keyboard-only users from operating invisible controls.
    var onInteract: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ± step (seconds) for the seek-back / seek-forward glyphs.
    private static let seekStep: Double = 10

    @State private var dragPosition: Double?
    @State private var tickedNow = Date()
    @State private var ticker: Task<Void, Never>?

    private var np: NowPlaying? { monitor.nowPlaying }
    private var duration: Double { np?.durationSeconds ?? 0 }
    private var available: Bool { monitor.availability == .available }
    private var scrubDisabled: Bool { !available || duration <= 0 }
    private var isPlaying: Bool { np?.state == .playing }

    private var displayed: Double {
        if let dragPosition { return dragPosition }
        return monitor.interpolatedPosition(now: tickedNow) ?? np?.positionSeconds ?? 0
    }

    var body: some View {
        VStack(spacing: 20) {
            scrubber
            controls
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)   // center the 640pt cluster in the screen
        .onAppear { startTicker() }
        .onDisappear { ticker?.cancel(); ticker = nil }
    }

    /// Run a transport command and reveal the chrome in one step. Wrapping the
    /// command means a keyboard shortcut fired while the chrome is hidden both
    /// acts and brings the controls back (and resets the idle timer).
    private func act(_ command: () -> Void) {
        onInteract()
        command()
    }

    private var scrubber: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let pct = duration > 0 ? max(0, min(1, displayed / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: geo.size.width * pct, height: 4)
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: geo.size.width * pct - 6)
                        .opacity(dragPosition != nil ? 1 : 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: 22)
            HStack {
                Text(format(displayed))
                Spacer()
                Text("−" + format(max(0, duration - displayed)))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
        .opacity(scrubDisabled ? 0.4 : 1)
        .allowsHitTesting(!scrubDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(format(displayed)) of \(format(duration))")
        .accessibilityAdjustableAction { dir in
            seekBy(dir == .increment ? Self.seekStep : -Self.seekStep)
        }
    }

    private var controls: some View {
        // Keyboard equivalents survive the hidden-chrome state (shortcuts fire
        // through the responder chain, not hit-testing): ← / → scrub ±10s,
        // ⌘← / ⌘→ skip tracks, space toggles play/pause. Each reveals chrome.
        HStack(spacing: 32) {
            glyph("backward.end.fill", "Previous track", size: 22,
                  key: .leftArrow, modifiers: .command) { act { monitor.previousTrack() } }
            glyph("gobackward.10", "Back 10 seconds", size: 25,
                  key: .leftArrow, modifiers: []) { seekBy(-Self.seekStep) }
            playPauseButton
            glyph("goforward.10", "Forward 10 seconds", size: 25,
                  key: .rightArrow, modifiers: []) { seekBy(Self.seekStep) }
            glyph("forward.end.fill", "Next track", size: 22,
                  key: .rightArrow, modifiers: .command) { act { monitor.nextTrack() } }
        }
        .opacity(available ? 1 : 0.4)
        .disabled(!available)
    }

    private var playPauseButton: some View {
        Button { act { monitor.playPause() } } label: {
            ZStack {
                Circle().fill(.white).frame(width: 62, height: 62)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    // Nudge the play triangle to its optical center.
                    .offset(x: isPlaying ? 0 : 2)
            }
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .help(isPlaying ? "Pause" : "Play")
    }

    private func glyph(_ symbol: String, _ label: String, size: CGFloat,
                       key: KeyEquivalent, modifiers: EventModifiers,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: modifiers)
        .accessibilityLabel(label)
        .help(label)
    }

    private func seekBy(_ delta: Double) {
        guard !scrubDisabled else { onInteract(); return }
        onInteract()
        let target = max(0, min(duration, displayed + delta))
        monitor.seek(to: target)
        // Hold the value briefly so the bar doesn't snap back before the next
        // poll lands (~500 ms).
        dragPosition = target
        let hold = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if dragPosition == hold { dragPosition = nil }
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard !scrubDisabled, duration > 0, width > 0 else { return }
                onInteract()
                dragPosition = max(0, min(1, g.location.x / width)) * duration
            }
            .onEnded { _ in
                guard !scrubDisabled, let target = dragPosition else { return }
                monitor.seek(to: target)
                let hold = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if dragPosition == hold { dragPosition = nil }
                }
            }
    }

    private func startTicker() {
        guard ticker == nil, !reduceMotion else { tickedNow = Date(); return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                tickedNow = Date()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func format(_ s: Double) -> String {
        let total = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - FlowLayout (wraps words across lines)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, totalW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW {
                y += rowH + spacing; x = 0; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            totalW = max(totalW, x)
        }
        return CGSize(width: totalW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        // Two-pass to center each row.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var rowW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if rowW + s.width > maxW && !rows[rows.count - 1].isEmpty {
                rows.append([]); rowW = 0
            }
            rows[rows.count - 1].append((v, s))
            rowW += s.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let totalW = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = bounds.minX + (maxW - totalW) / 2
            let h = row.map { $0.1.height }.max() ?? 0
            for (v, s) in row {
                v.place(at: CGPoint(x: x, y: y + (h - s.height) / 2),
                        proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + spacing
        }
    }
}

// MARK: - Active-line index (kept for backwards compat)

extension LyricLine {
    static func activeIndex(in lines: [LyricLine], at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        if position < lines[0].timestamp { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].timestamp <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Pill capsule frame reporter

/// Reports the visible capsule's frame in the named coordinate space (which
/// is anchored at the SwiftUI host's contentView origin) to the shared
/// `PillHitTarget`. The controller reads this rect to gate
/// `ignoresMouseEvents` so transparent areas around the capsule pass clicks
/// through to the desktop.
struct PillCapsuleFrameReporter: ViewModifier {
    let space: String
    @ObservedObject var hitTarget: PillHitTarget

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PillCapsuleFramePreferenceKey.self,
                    value: geo.frame(in: .named(space))
                )
            }
        )
        .onPreferenceChange(PillCapsuleFramePreferenceKey.self) { rect in
            Task { @MainActor in
                if hitTarget.capsuleRectInContentView != rect {
                    hitTarget.capsuleRectInContentView = rect
                }
            }
        }
    }
}

private struct PillCapsuleFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Visual effect bridge

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
