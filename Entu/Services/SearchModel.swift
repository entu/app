import Foundation

/// Holds the current search query text, accessible from any view.
@MainActor @Observable
final class SearchModel {
    /// The current search query entered by the user.
    var text = ""

    /// True when the user has typed something in the search field.
    var isActive: Bool { !text.isEmpty }
}
