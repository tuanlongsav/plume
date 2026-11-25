import Foundation

/// Tiny vi/en string picker — Plume's UI copy is bilingual per the handoff.
public enum L {
    /// The user's first preferred language, which is what System Settings
    /// (including a per-app language) sets. Plume ships no `.lproj` folders,
    /// so `Locale.current` has no app localization to report. Read once: the
    /// menus are built once too, and `t` runs on every menu validation.
    public static let isVI: Bool = {
        let preferred = Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
        return preferred.language.languageCode?.identifier == "vi"
    }()

    public static func t(_ vi: String, _ en: String) -> String { isVI ? vi : en }
}
