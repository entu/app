// In-app language preference and the helpers everything else reads to honour it.
//
// SwiftUI views handle their own localization via `\.environment(\.locale, ...)`
// at app root — `Text("key")`, `Button("key")`, `.alert("key", …)` etc. all
// observe the env locale. This file covers the few places that need the
// preference outside that path:
//   - `Bundle.currentLocalized` — for the handful of pure-Swift `String`
//     contexts (`String(format:)` titles, model-side error strings).
//   - `PropertyValue.localized(...)` — for server-supplied multilingual
//     values where the API returns one entry per language.
//   - `EntityDetailModel.typeCache` / `MenuModel.cache` — for keying entries
//     by language so switching back is instant.
//
// One UserDefaults key (`ui.appLanguage`) drives everything.

import SwiftUI

/// Available in-app language overrides. The raw value is the ISO code stored
/// in `@AppStorage("ui.appLanguage")`; an empty string means "follow system".
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case estonian = "et"

    static let storageKey = "ui.appLanguage"

    var id: String { rawValue }

    /// Localized display label for the picker — `LocalizedStringKey` so SwiftUI
    /// resolves it against the active env locale.
    var label: LocalizedStringKey {
        switch self {
        case .system: return "languageSystem"
        case .english: return "languageEnglish"
        case .estonian: return "languageEstonian"
        }
    }

    /// `.lproj` bundle for this language, or `.main` for `.system`.
    var bundle: Bundle {
        guard self != .system,
              let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }

        return bundle
    }

    /// Active preference, read from UserDefaults on every access.
    static var current: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AppLanguage(rawValue: stored) ?? .system
    }

    /// Two-letter language code used for matching server-supplied multilingual
    /// values. Falls back to the system preferred language when the in-app
    /// preference is `.system`.
    static var resolvedLanguageCode: String {
        let current = AppLanguage.current
        if current != .system {
            return current.rawValue
        }

        return Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
    }
}

extension Bundle {
    /// Bundle for the active in-app language, or `.main` when following the
    /// system. Resolves on every access.
    static var currentLocalized: Bundle {
        AppLanguage.current.bundle
    }
}
