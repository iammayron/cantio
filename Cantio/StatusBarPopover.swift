import AppKit
import SwiftUI
import Combine

/// Custom menu-bar dropdown built on `NSStatusItem` + a borderless `NSPanel`,
/// replacing SwiftUI's `MenuBarExtra(.window)`. The Scene API installs an
/// opaque `MenuBarExtraWindow` whose hosting view chain renders panel content
/// against an in-window backing — which means `.glassEffect()` blurs that
/// in-window backing instead of the desktop, defeating Liquid Glass on
/// macOS 26. Owning our own `NSPanel` (level `.popUpMenu`, `isOpaque = false`,
/// `backgroundColor = .clear`) lets `.glassEffect()` render the way Apple's
/// own Battery / Wi-Fi dropdowns do.
@MainActor
final class StatusBarPopover: NSObject, NSWindowDelegate {
    private static let maxTitleWidth: CGFloat = 260
    private static let marqueeStepInterval: TimeInterval = 1.0 / 30.0
    private static let marqueePointsPerSecond: CGFloat = 18
    private static let statusTitlePadding: CGFloat = 14
    /// Gap between the fixed note glyph and the (possibly scrolling) title.
    private static let noteTitleGap: CGFloat = 4
    /// Minimum overflow (points) before the marquee animates. Below this the
    /// title is truncated instead — avoids a frantic 1–2pt bounce when the
    /// title nearly fits.
    private static let marqueeOverflowThreshold: CGFloat = 24
    private static let noteGlyph = "♪"

    private let statusItem: NSStatusItem
    private let monitor: SpotifyMonitor
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var contentBuilder: (() -> AnyView)?
    private var cancellables = Set<AnyCancellable>()
    private var marqueeTimer: Timer?
    /// Title text only — no note prefix. Empty when nothing is playing
    /// (status item then shows just the note glyph).
    private var statusTitleText = ""
    private var marqueeOffset: CGFloat = 0
    private var marqueeDirection: CGFloat = 1
    /// Tracks whether the last update saw playback running, so we know when
    /// to start/stop the marquee on play-state transitions.
    private var lastIsPlaying = false

    init(monitor: SpotifyMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.mayronalves.cantio.statusItem"
        super.init()
        configureStatusItem()
        observeMonitor()
    }

    func setContent<Content: View>(@ViewBuilder _ content: @escaping () -> Content) {
        contentBuilder = { AnyView(content()) }
        if let panel, let view = panel.contentView as? NSHostingView<AnyView> {
            view.rootView = AnyView(content())
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.toolTip = "Cantio"
        button.identifier = NSUserInterfaceItemIdentifier("com.mayronalves.cantio.statusButton")
        button.setAccessibilityLabel("Cantio")
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byClipping
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateStatusItemLabel()
    }

    private func observeMonitor() {
        monitor.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemLabel() }
            .store(in: &cancellables)
    }

    private func updateStatusItemLabel() {
        guard let button = statusItem.button else { return }
        if let displayText {
            button.toolTip = "Cantio: \(displayText)"
            button.setAccessibilityLabel("Cantio: \(displayText)")
        } else {
            button.toolTip = "Cantio"
            button.setAccessibilityLabel("Cantio")
        }
        let nextTitle = displayText ?? ""
        let titleChanged = nextTitle != statusTitleText
        let playingChanged = isPlaying != lastIsPlaying
        if titleChanged {
            statusTitleText = nextTitle
            marqueeOffset = 0
            marqueeDirection = 1
            updateStatusButtonFrame()
        }
        if titleChanged || playingChanged {
            lastIsPlaying = isPlaying
            updateMarqueeTimer()
            if !titleChanged { updateStatusButtonFrame() }
        }
        statusItem.isVisible = true
    }

    private func updateStatusButtonFrame() {
        guard let button = statusItem.button else { return }
        if statusTitleText.isEmpty {
            button.image = nil
            button.attributedTitle = statusAttributedTitle(Self.noteGlyph)
            statusItem.length = NSStatusItem.squareLength
        } else {
            button.attributedTitle = NSAttributedString()
            button.image = renderStatusTitle(offset: marqueeOffset)
            button.imagePosition = .imageOnly
            statusItem.length = totalImageWidth
        }
    }

    private func updateMarqueeTimer() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil

        guard titleOverflow > Self.marqueeOverflowThreshold,
              isPlaying,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }

        let timer = Timer(timeInterval: Self.marqueeStepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceMarquee() }
        }
        RunLoop.main.add(timer, forMode: .common)
        marqueeTimer = timer
    }

    private var noteGlyphWidth: CGFloat {
        ceil(statusAttributedTitle(Self.noteGlyph).size().width)
    }

    private var titleIntrinsicWidth: CGFloat {
        ceil(statusAttributedTitle(statusTitleText).size().width)
    }

    /// Width budgeted for the title region (after note glyph + padding).
    private var titleAvailableWidth: CGFloat {
        let pad = Self.statusTitlePadding
        return max(0, Self.maxTitleWidth - pad - noteGlyphWidth - Self.noteTitleGap)
    }

    private var titleOverflow: CGFloat {
        max(0, titleIntrinsicWidth - titleAvailableWidth)
    }

    /// Width of the rendered status item image: note + gap + min(title, available).
    private var totalImageWidth: CGFloat {
        let pad = Self.statusTitlePadding
        let visibleTitle = min(titleIntrinsicWidth, titleAvailableWidth)
        return pad + noteGlyphWidth + Self.noteTitleGap + visibleTitle
    }

    private func advanceMarquee() {
        guard !statusTitleText.isEmpty else { return }
        let maxOffset = titleOverflow
        marqueeOffset += marqueeDirection * Self.marqueePointsPerSecond * Self.marqueeStepInterval
        if marqueeOffset >= maxOffset {
            marqueeOffset = maxOffset
            marqueeDirection = -1
        } else if marqueeOffset <= 0 {
            marqueeOffset = 0
            marqueeDirection = 1
        }
        updateStatusButtonFrame()
    }

    private func statusAttributedTitle(_ title: String, truncating: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        paragraph.alignment = .left
        let menuBarFont = NSFont.menuBarFont(ofSize: 0)
        let font = NSFont.systemFont(ofSize: menuBarFont.pointSize, weight: .semibold)
        return NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func renderStatusTitle(offset: CGFloat) -> NSImage {
        let imageWidth = totalImageWidth
        let imageHeight = NSStatusBar.system.thickness
        let imageSize = NSSize(width: imageWidth, height: imageHeight)
        let scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let pixelsWide = max(1, Int(ceil(imageWidth * scale)))
        let pixelsHigh = max(1, Int(ceil(imageHeight * scale)))
        let image = NSImage(size: imageSize)
        let isMarqueeing = marqueeTimer != nil

        let noteAttr = NSMutableAttributedString(attributedString: statusAttributedTitle(Self.noteGlyph))
        noteAttr.addAttribute(.foregroundColor, value: NSColor.black,
                              range: NSRange(location: 0, length: noteAttr.length))
        let titleAttr = NSMutableAttributedString(
            attributedString: statusAttributedTitle(statusTitleText, truncating: !isMarqueeing)
        )
        titleAttr.addAttribute(.foregroundColor, value: NSColor.black,
                               range: NSRange(location: 0, length: titleAttr.length))

        let textHeight = max(noteAttr.size().height, titleAttr.size().height)
        let y = (imageHeight - textHeight) / 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaFirst],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            image.isTemplate = true
            return image
        }

        rep.size = imageSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        NSGraphicsContext.current?.shouldAntialias = true

        let leftInset = Self.statusTitlePadding / 2
        // Note glyph: always at fixed left position.
        noteAttr.draw(at: CGPoint(x: leftInset, y: y))

        // Title: drawn inside a clipped rect to the right of the note. Marquee
        // shifts the draw origin within that clip; truncating mode draws into
        // a bounded rect so AppKit inserts an ellipsis when needed.
        let titleX = leftInset + noteGlyphWidth + Self.noteTitleGap
        let titleClip = NSRect(x: titleX, y: 0,
                               width: titleAvailableWidth,
                               height: imageHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: titleClip).addClip()
        if isMarqueeing {
            titleAttr.draw(at: CGPoint(x: titleX - offset, y: y))
        } else {
            titleAttr.draw(in: NSRect(x: titleX, y: y,
                                      width: titleAvailableWidth,
                                      height: titleAttr.size().height))
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private var displayText: String? {
        guard let np = monitor.nowPlaying, !np.title.isEmpty,
              np.state != .stopped else { return nil }
        let artist = np.artist.trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? np.title : "\(np.title) · \(artist)"
    }

    /// Marquee should only run when audio is actually moving — pausing
    /// freezes the title so the menu bar doesn't dance over a static song.
    private var isPlaying: Bool {
        monitor.nowPlaying?.state == .playing
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            close()
        } else {
            open()
        }
    }

    /// Dismiss the dropdown programmatically. Used by in-panel actions that
    /// open another window (Settings) — opening it defers activation across
    /// runloop ticks (see `SettingsActivator`), so the panel never resigns
    /// key on its own and must be closed explicitly.
    func dismiss() {
        guard panel?.isVisible == true else { return }
        close()
    }

    private func open() {
        guard let builder = contentBuilder else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.rootView = builder()
        }
        positionPanel(panel)
        // Activate so the panel can receive key events (Esc, ⌘,, etc.).
        // `.nonactivatingPanel` keeps Cantio from stealing app activation
        // from the frontmost app, matching menubar dropdown semantics.
        NSApp.activate(ignoringOtherApps: false)
        panel.makeKeyAndOrderFront(nil)
        installEventMonitors()
        // The action fires on `.leftMouseDown`, so we're still inside AppKit's
        // button tracking — it clears the highlight on mouse-up, flashing the
        // selection. Re-assert after the event drains so it sticks while the
        // panel is open.
        DispatchQueue.main.async { [weak self] in
            guard self?.panel?.isVisible == true else { return }
            self?.statusItem.button?.highlight(true)
        }
    }

    private func close() {
        panel?.orderOut(nil)
        removeEventMonitors()
        statusItem.button?.highlight(false)
    }

    /// AppKit shoves any window whose top crosses the menu bar back down to
    /// `visibleFrame.maxY`. The panel deliberately overhangs it by
    /// `MenuBarPanel.glassMargin` — that slack is transparent shadow room, and
    /// letting it be constrained away pushes the *visible* glass down by the
    /// same 24pt, which is exactly the gap that marks a panel as non-native.
    private final class UnconstrainedPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    private func makePanel() -> NSPanel {
        let p = UnconstrainedPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 360),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        // No AppKit window shadow: `.glassEffect()` paints none of its own
        // either, so `MenuBarPanel` draws the drop shadow in SwiftUI, shaped
        // to the glass rather than to the rectangular window (see the comment
        // on `MenuBarPanel.body`).
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.animationBehavior = .utilityWindow
        p.delegate = self

        let content = NSHostingView(rootView: AnyView(EmptyView()))
        content.translatesAutoresizingMaskIntoConstraints = false
        // Size to fit the SwiftUI content's intrinsic dimensions.
        content.sizingOptions = [.intrinsicContentSize]
        // Liquid Glass samples whatever sits behind it in the layer chain.
        // NSHostingView is layer-backed by default, but its layer's
        // backgroundColor isn't guaranteed to be transparent — explicitly
        // clear it (and the panel's contentView wrapper, just in case)
        // so `.glassEffect()` blurs the desktop instead of an opaque host.
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = content
        if let cv = p.contentView {
            cv.wantsLayer = true
            cv.layer?.backgroundColor = NSColor.clear.cgColor
        }
        return p
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        // Convert the button frame into screen coordinates, then position the
        // panel just below it, right-aligned with the status item (matches
        // system dropdown placement).
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)

        // Let SwiftUI lay out so we can ask for the intrinsic size.
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.layoutSubtreeIfNeeded()
        }
        // The SwiftUI content pads the glass by `glassMargin` on every side so
        // its shadow has room to draw; `inset` is that slack, subtracted back
        // out below so the *visible* panel lands where it always did.
        let inset = MenuBarPanel.glassMargin
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: 290, height: 360)
        let width = max(fittingSize.width, 290 + inset * 2)
        let height = max(fittingSize.height, 80)

        // Default left-align: panel's left edge under the status item's left
        // edge. If the panel would spill off the right edge, flip to
        // right-aligned (panel's right edge under the status item's right
        // edge) — same fallback the system menus use.
        let visible = screen.visibleFrame
        let edgeMargin: CGFloat = 6
        var originX = buttonRectOnScreen.minX - inset
        if originX + width - inset > visible.maxX - edgeMargin {
            originX = buttonRectOnScreen.maxX - width + inset
        }
        originX = min(max(originX, visible.minX + edgeMargin - inset),
                      visible.maxX - width - edgeMargin + inset)
        // Anchor Y to the screen's visible top — i.e. the menu bar's bottom
        // edge — not to `buttonRectOnScreen.minY`. macOS 27 collapsed the menu
        // bar into a single window, and the status button's converted frame no
        // longer sits flush with the visible bar: anchoring to it dropped the
        // panel a measured 24pt. No gap: Apple's own dropdowns (Control Centre,
        // Battery, Now Playing) sit flush with the bar — a few points of air is
        // the tell that a panel is not native.
        let menuBarBottom = visible.maxY
        let origin = NSPoint(x: originX,
                             y: menuBarBottom - height + inset)
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)),
                       display: true)
    }

    // MARK: - Outside-click + Esc dismissal

    private func installEventMonitors() {
        removeEventMonitors()
        // Click outside the panel anywhere on screen → dismiss.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // Esc inside the panel → dismiss. Cmd-Q quit / Cmd-, Settings continue
        // to flow through the responder chain via SwiftUI keyboard shortcuts.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 /* Escape */ {
                self.close()
                return nil
            }
            // Click on the status item itself comes through the local monitor
            // when Cantio is key — let `togglePanel` handle it (return event so
            // AppKit dispatches it normally, which closes via the toggle path).
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window === self.statusItem.button?.window {
                    self.close()
                    return nil
                }
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Resign-key fires when the user clicks any other window — treat as
        // dismiss to mirror system dropdown behaviour.
        close()
    }
}
