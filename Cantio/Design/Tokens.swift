import SwiftUI
import AppKit

/// Cantio design tokens — palette, type, radii, easing.
///
/// Mirrors the `tokens.jsx` from the design handoff. OKLCH values are
/// converted to sRGB at runtime so the perceptual hue ramp matches the
/// prototype across light/dark tones.
enum FL {
    enum Tone { case dark, light }

    struct Palette {
        let bg: Color
        let bgElev: Color
        let glass: Color
        let glassThin: Color
        let border: Color
        let borderStrong: Color
        let text: Color
        let textMuted: Color
        let textFaint: Color
        let accent: Color
        let accentSoft: Color
    }

    /// Opaque fill for the floating player's Black background. Tone-independent:
    /// the player always renders its dark palette over it.
    static let playerBlack = Color(.sRGB, red: 12/255, green: 12/255, blue: 14/255, opacity: 1)

    static func palette(tone: Tone, hue: Double = 220) -> Palette {
        switch tone {
        case .dark:
            return Palette(
                bg: oklch(0.18, 0.008, 250),
                bgElev: oklch(0.22, 0.01, 250),
                glass: Color(.sRGB, red: 28/255, green: 30/255, blue: 36/255, opacity: 0.55),
                glassThin: Color(.sRGB, red: 28/255, green: 30/255, blue: 36/255, opacity: 0.32),
                border: .white.opacity(0.08),
                borderStrong: .white.opacity(0.14),
                text: oklch(0.97, 0.005, 250),
                textMuted: oklch(0.72, 0.01, 250),
                textFaint: oklch(0.52, 0.01, 250),
                accent: oklch(0.78, 0.12, hue),
                accentSoft: oklch(0.78, 0.12, hue).opacity(0.18)
            )
        case .light:
            return Palette(
                bg: oklch(0.985, 0.004, 250),
                bgElev: .white,
                glass: Color(.sRGB, red: 248/255, green: 248/255, blue: 250/255, opacity: 0.62),
                glassThin: Color(.sRGB, red: 248/255, green: 248/255, blue: 250/255, opacity: 0.42),
                border: .black.opacity(0.08),
                borderStrong: .black.opacity(0.14),
                text: oklch(0.18, 0.008, 250),
                textMuted: oklch(0.42, 0.01, 250),
                textFaint: oklch(0.62, 0.01, 250),
                accent: oklch(0.62, 0.13, hue),
                accentSoft: oklch(0.62, 0.13, hue).opacity(0.14)
            )
        }
    }

    /// Approximate OKLCH → sRGB. L: 0..1, C: chroma, hDeg: 0..360.
    static func oklch(_ L: Double, _ C: Double, _ hDeg: Double) -> Color {
        let h = hDeg * .pi / 180
        let a = C * cos(h)
        let b = C * sin(h)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return Color(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(bl), opacity: 1)
    }

    private static func gamma(_ v: Double) -> Double {
        let c = max(0, min(1, v))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1/2.4) - 0.055
    }
}
