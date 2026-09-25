import Foundation
import Combine
import ServiceManagement

/// Display mode for the floating lyrics window. Retained for backward
/// compatibility; new UI prefers `linesVisible` (1 = single, >1 = stack).
enum LyricsDisplayMode: String, CaseIterable, Identifiable {
    case singleLine
    case multiLine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleLine: return "Single line"
        case .multiLine: return "Multi-line"
        }
    }
}

/// Window silhouette — controls layout / chrome.
enum WindowStyle: String, CaseIterable, Identifiable {
    case floating
    case fullscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .floating: return "Floating"
        case .fullscreen: return "Fullscreen"
        }
    }
}

/// Background fill for windowed styles (currently `minimal`). Pill and
/// fullscreen render their own backdrop and ignore this.
enum BackgroundStyle: String, CaseIterable, Identifiable {
    case glass
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .solid: return "Solid"
        }
    }
}

/// Liquid Glass material style for pill + menubar panel. macOS 26+ only;
/// runtime-forced to `.off` on older systems via `effectiveGlassStyle`.
enum GlassStyle: String, CaseIterable, Identifiable {
    case off
    case clear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .clear: return "Clear"
        }
    }
}

/// Fill behind the floating player window.
enum PlayerBackground: String, CaseIterable, Identifiable {
    case glass
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .black: return "Black"
        }
    }
}

enum FontSize: Int, CaseIterable, Identifiable, Comparable {
    case xsmall = -1
    case small = 0
    case medium = 1
    case large = 2
    case xlarge = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .xsmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .xlarge: return "Extra Large"
        }
    }

    /// Abbreviation for compact controls (segmented pickers); full `label`
    /// stays the VoiceOver-spoken name.
    var shortLabel: String {
        switch self {
        case .xsmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .xlarge: return "XL"
        }
    }

    var activeSize: CGFloat {
        switch self {
        case .xsmall: return 14
        case .small: return 18
        case .medium: return 22
        case .large: return 26
        case .xlarge: return 32
        }
    }

    var bodySize: CGFloat {
        switch self {
        case .xsmall: return 10
        case .small: return 12
        case .medium: return 14
        case .large: return 16
        case .xlarge: return 18
        }
    }

    static func < (lhs: FontSize, rhs: FontSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let displayMode = "displayMode"
        static let windowStyle = "windowStyle"
        static let backgroundStyle = "backgroundStyle"
        static let glassStyle = "glassStyle"
        static let legacyGlassOpacity = "glassOpacity"
        static let legacyWindowPreset = "windowPreset"
        static let legacyTone = "tone"
        static let accentHue = "accentHue"
        static let fontSize = "fontSize"
        static let legacyClickThrough = "clickThrough"
        static let hideWhenPaused = "hideWhenPaused"
        static let alwaysOnTop = "alwaysOnTop"
        static let windowVisible = "windowVisible"
        static let playerVisible = "playerVisible"
        static let playerBackground = "playerBackground"
        static let launchAtLogin = "launchAtLogin"
        static let linesVisible = "linesVisible"
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let hotKeyKeyCode = "hotKey.keyCode"
        static let hotKeyModifiers = "hotKey.modifiers"
    }

    @Published var displayMode: LyricsDisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    @Published var windowStyle: WindowStyle {
        didSet {
            defaults.set(windowStyle.rawValue, forKey: Key.windowStyle)
            displayMode = (linesVisible <= 1) ? .singleLine : .multiLine
        }
    }

    @Published var backgroundStyle: BackgroundStyle {
        didSet { defaults.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle) }
    }

    @Published var glassStyle: GlassStyle {
        didSet {
            defaults.set(glassStyle.rawValue, forKey: Key.glassStyle)
            // Mirror to legacy `backgroundStyle` so the minimal-window legacy
            // background path (still expressed in terms of glass/solid in
            // `LyricsContentView.background`) tracks the user's only visible
            // toggle. Avoid an infinite loop by only writing when the mapped
            // value differs from current.
            let mapped: BackgroundStyle = (glassStyle == .off) ? .solid : .glass
            if backgroundStyle != mapped { backgroundStyle = mapped }
        }
    }

    /// Liquid Glass APIs ship on macOS 26+. On older systems the material is
    /// unavailable at runtime, so force `.off` regardless of the stored pref.
    var effectiveGlassStyle: GlassStyle {
        if #available(macOS 26, *) { return glassStyle }
        return .off
    }

    static var defaultGlassStyle: GlassStyle {
        if #available(macOS 26, *) { return .clear }
        return .off
    }

    @Published var accentHue: Double {
        didSet { defaults.set(accentHue, forKey: Key.accentHue) }
    }

    @Published var fontSize: FontSize {
        didSet { defaults.set(fontSize.rawValue, forKey: Key.fontSize) }
    }

    @Published var hideWhenPaused: Bool {
        didSet { defaults.set(hideWhenPaused, forKey: Key.hideWhenPaused) }
    }

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }

    @Published var windowVisible: Bool {
        didSet { defaults.set(windowVisible, forKey: Key.windowVisible) }
    }

    @Published var playerVisible: Bool {
        didSet { defaults.set(playerVisible, forKey: Key.playerVisible) }
    }

    @Published var playerBackground: PlayerBackground {
        didSet { defaults.set(playerBackground.rawValue, forKey: Key.playerBackground) }
    }

    static var defaultPlayerBackground: PlayerBackground {
        if #available(macOS 26, *) { return .glass }
        return .black
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    @Published var linesVisible: Int {
        didSet {
            defaults.set(linesVisible, forKey: Key.linesVisible)
            displayMode = (linesVisible <= 1) ? .singleLine : .multiLine
        }
    }

    @Published var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Key.didCompleteOnboarding) }
    }

    @Published var toggleHotKey: HotKey {
        didSet {
            defaults.set(Int(toggleHotKey.keyCode), forKey: Key.hotKeyKeyCode)
            defaults.set(Int(toggleHotKey.modifiers), forKey: Key.hotKeyModifiers)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let legacyPresetRaw = defaults.string(forKey: Key.legacyWindowPreset)
        let styleRaw = defaults.string(forKey: Key.windowStyle)
        let bgRaw = defaults.string(forKey: Key.backgroundStyle)

        if let styleRaw, let s = WindowStyle(rawValue: styleRaw) {
            self.windowStyle = s
        } else if styleRaw == "pill" {
            // Renamed `.pill` → `.floating` (display + raw value).
            self.windowStyle = .floating
        } else {
            switch legacyPresetRaw {
            case "fullscreen": self.windowStyle = .fullscreen
            default: self.windowStyle = .floating
            }
        }
        if let bgRaw, let b = BackgroundStyle(rawValue: bgRaw) {
            self.backgroundStyle = b
        } else {
            self.backgroundStyle = (legacyPresetRaw == "solid") ? .solid : .glass
        }
        // L1: glassStyle migration. Stored value wins; otherwise derive from
        // legacy `backgroundStyle` raw (one-shot) and drop the legacy key.
        let storedGlass = defaults.string(forKey: Key.glassStyle)
        if let storedGlass, let g = GlassStyle(rawValue: storedGlass) {
            self.glassStyle = g
        } else if storedGlass == "tinted" {
            // `.tinted` was retired. Existing stored prefs migrate to `.clear`.
            self.glassStyle = .clear
        } else if let bgRaw {
            switch bgRaw {
            case "glass": self.glassStyle = Self.defaultGlassStyle
            case "solid": self.glassStyle = .off
            default: self.glassStyle = Self.defaultGlassStyle
            }
            defaults.removeObject(forKey: Key.backgroundStyle)
        } else {
            self.glassStyle = Self.defaultGlassStyle
        }
        // Drop the legacy `tone` override; menu bar + lyrics window now follow
        // the system appearance. Discard the stored value if present.
        defaults.removeObject(forKey: Key.legacyTone)
        // Tint strength + Tinted style were dropped (slider was a no-op
        // and Tinted clashed with native Liquid Glass). Discard the stored
        // value if present.
        defaults.removeObject(forKey: Key.legacyGlassOpacity)

        self.accentHue = defaults.object(forKey: Key.accentHue) as? Double ?? 220

        let raw = defaults.string(forKey: Key.displayMode) ?? LyricsDisplayMode.singleLine.rawValue
        self.displayMode = LyricsDisplayMode(rawValue: raw) ?? .singleLine
        if defaults.object(forKey: Key.fontSize) == nil {
            self.fontSize = .medium
        } else {
            self.fontSize = FontSize(rawValue: defaults.integer(forKey: Key.fontSize)) ?? .medium
        }
        // W4: clickThrough is now derived from windowStyle. Discard legacy stored value.
        defaults.removeObject(forKey: Key.legacyClickThrough)
        if defaults.object(forKey: Key.hideWhenPaused) == nil {
            self.hideWhenPaused = true
        } else {
            self.hideWhenPaused = defaults.bool(forKey: Key.hideWhenPaused)
        }
        if defaults.object(forKey: Key.alwaysOnTop) == nil {
            self.alwaysOnTop = true
        } else {
            self.alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        }
        if defaults.object(forKey: Key.windowVisible) == nil {
            self.windowVisible = true
        } else {
            self.windowVisible = defaults.bool(forKey: Key.windowVisible)
        }
        self.playerVisible = defaults.bool(forKey: Key.playerVisible)
        self.playerBackground = defaults.string(forKey: Key.playerBackground)
            .flatMap(PlayerBackground.init(rawValue:)) ?? Self.defaultPlayerBackground
        let storedLaunch = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        self.launchAtLogin = Self.currentLoginItemEnabled(fallback: storedLaunch)
        self.linesVisible = defaults.object(forKey: Key.linesVisible) as? Int ?? 3
        self.didCompleteOnboarding = defaults.bool(forKey: Key.didCompleteOnboarding)
        if defaults.object(forKey: Key.hotKeyKeyCode) == nil {
            self.toggleHotKey = .defaultToggle
        } else {
            let keyCode = UInt32(defaults.integer(forKey: Key.hotKeyKeyCode))
            let mods = UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            self.toggleHotKey = HotKey(keyCode: keyCode, modifiers: mods)
        }
    }

    // MARK: - Launch at login

    private static func currentLoginItemEnabled(fallback: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return true
            case .notRegistered, .notFound, .requiresApproval: return false
            @unknown default: return fallback
            }
        }
        return fallback
    }

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("Cantio: failed to update login item: \(error.localizedDescription)")
        }
    }
}
