import AppKit

/// Design tokens from the redesign handoff, mapped to AppKit.
/// Brand colours are fixed sRGB; surface colours are dynamic so they follow
/// the effective light/dark appearance.
enum Theme {
    // MARK: Brand
    static let blue500  = srgb(0x3B82F6)   // gradient start
    static let indigo600 = srgb(0x4F46E5)  // accent-solid
    static let indigo700 = srgb(0x4338CA)  // gradient end
    static let accent = indigo600

    /// Gradient used *sparingly* (splash feather, primary button).
    static var gradientColors: [CGColor] { [blue500.cgColor, indigo700.cgColor] }

    // MARK: Surfaces (dynamic light/dark)
    /// Full-bleed background behind splash / offline states.
    static let stateBackground = dynamic(light: 0xFBFBFD, dark: 0x141517)

    // MARK: Text — reuse system semantic colours (already appearance-aware)
    static var textPrimary: NSColor   { .labelColor }
    static var textSecondary: NSColor { .secondaryLabelColor }
    static var textTertiary: NSColor  { .tertiaryLabelColor }

    // MARK: Motion
    /// Honour the system "Reduce Motion" setting — callers skip looping
    /// animations (breathing / shimmer / progress) when this is true.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Helpers
    private static func srgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:    CGFloat((hex >> 8) & 0xFF) / 255,
                blue:     CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? srgb(dark) : srgb(light)
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSView {
    /// Resolve appearance-dependent colours (e.g. into CALayers) under this
    /// view's effective appearance. CGColors captured outside this block use
    /// whatever appearance happened to be current.
    func withEffectiveAppearance(_ body: () -> Void) {
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance(body)
        } else {
            let saved = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            body()
            NSAppearance.current = saved
        }
    }
}

/// Tiny vi/en string picker — Plume's UI copy is bilingual per the handoff.
enum L {
    static var isVI: Bool {
        Locale.current.language.languageCode?.identifier == "vi"
    }
    static func t(_ vi: String, _ en: String) -> String { isVI ? vi : en }
}
