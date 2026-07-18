// Match highlighting shared by search UIs — the typed text rendered
// bold inside a result title, per the design ("**Roo**sleht, Milvi").

import Foundation

extension String {
    /// The first case- and diacritic-insensitive occurrence of `query`
    /// marked strongly emphasized (bold); the plain string when `query`
    /// is empty or absent.
    func emphasizing(_ query: String) -> AttributedString {
        var attributed = AttributedString(self)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           let range = attributed.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
