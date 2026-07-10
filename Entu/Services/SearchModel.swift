import Foundation

/// Holds the current search query text, accessible from any view.
@MainActor @Observable
final class SearchModel {
    /// The current search query entered by the user.
    var text = ""

    /// Serialized advanced-search query (e.g. "_type.string=person&sort=-name.string").
    /// `q` is excluded — it lives in `text` so the toolbar search field stays
    /// editable, mirroring the webapp where the toolbar field and the search
    /// modal both write the same route-query `q` param. Nil means advanced
    /// search is not applied; empty string means applied with no filters.
    var advancedQuery: String?

    /// True when the user has typed something or applied an advanced search.
    var isActive: Bool { !text.isEmpty || advancedQuery != nil }

    /// Presents the advanced-search sheet. Set from any toolbar button;
    /// the sheet itself is hosted once by `MainView`.
    var showAdvanced = false

    /// Feature flag: temporarily hides every advanced-search button. The
    /// sheet, apply logic, and query wiring stay intact — flip to `true` to
    /// restore the button everywhere.
    static let showAdvancedButton = false
}
