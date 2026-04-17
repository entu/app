// Global search state — shared across all views via @Environment.
// Persists when the NavigationSplitView layout changes between two/three-column.

import Foundation

/// Holds the current search query text, accessible from any view.
@MainActor @Observable
final class SearchModel {
    /// The current search query entered by the user.
    var text = ""

    /// True when the user has typed something in the search field.
    var isActive: Bool { !text.isEmpty }
}
