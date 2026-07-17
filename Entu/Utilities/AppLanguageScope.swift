// In-app language switching — a modifier every presentation root applies
// so sheets and popovers (which don't inherit the app-root locale) render
// in the chosen language, plus the language preference itself.

import SwiftUI

/// Re-applies the in-app language to a view tree.
///
/// SwiftUI presents sheets, popovers and covers in a fresh environment that
/// does not inherit the app-root locale, so each presentation root must
/// re-apply the chosen language or its `LocalizedStringKey`s fall back to the
/// system locale. Re-keying on the language also forces a rebuild so lookups
/// cached against `Bundle.main`'s launch localization re-resolve.
private struct AppLanguageScope: ViewModifier {
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    func body(content: Content) -> some View {
        content
            .id(appLanguage)
            .environment(\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))
    }
}

extension View {
    /// Scope this view tree to the in-app language. Apply to every separately
    /// presented root (sheet, popover, cover) whose content shows localized
    /// text — the app root sets the locale, but presentations don't inherit it.
    func appLanguageScoped() -> some View {
        modifier(AppLanguageScope())
    }
}
