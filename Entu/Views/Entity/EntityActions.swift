import SwiftUI

/// Rights-gated actions for the entity currently shown in the detail
/// column. Published by `EntityToolbarHost` via `.focusedSceneValue` so
/// the File-menu `EntityCommands` (and their keyboard shortcuts) drive
/// the same feature sheets as the toolbar buttons. A `nil` closure means
/// the user lacks the required right — the menu item disables.
///
/// `Equatable` on the *availability* of each action (not the closures,
/// which change every render): lets SwiftUI dedupe the focused-value
/// updates so a burst of re-renders during entity load doesn't republish
/// many times per frame (which merely warns on macOS but can freeze iPad).
struct EntityActions: Equatable {
    var edit: (() -> Void)?
    var duplicate: (() -> Void)?
    var parents: (() -> Void)?
    var rights: (() -> Void)?
    var history: (() -> Void)?

    static func == (lhs: EntityActions, rhs: EntityActions) -> Bool {
        (lhs.edit == nil) == (rhs.edit == nil)
            && (lhs.duplicate == nil) == (rhs.duplicate == nil)
            && (lhs.parents == nil) == (rhs.parents == nil)
            && (lhs.rights == nil) == (rhs.rights == nil)
            && (lhs.history == nil) == (rhs.history == nil)
    }
}

/// One "create an entity of this type" choice for the File > New and
/// File > Add Child menu commands. Mirrors a single option of the
/// toolbar's Add button/menu — `create` sets the same create-sheet state.
struct EntityCreateOption: Identifiable {
    let id: String          // type _id
    let label: String       // type label in the active in-app language
    let menuLabel: String   // English label for the menu bar (system language)
    let create: () -> Void
}

/// A create command surfaced in the File menu with a keyboard shortcut.
/// `options` drives the menu-item label (single vs multiple types);
/// `invoke` runs the shortcut: it creates directly when there's one type,
/// or asks the publishing view to present a type chooser when there are
/// several (SwiftUI can't open the toolbar's Add menu programmatically, so
/// the shortcut opens an equivalent picker instead).
///
/// `Equatable` on the option ids (not the closures) so SwiftUI dedupes the
/// focused-value updates — see `EntityActions`.
struct EntityCreateCommand: Equatable {
    let options: [EntityCreateOption]
    let invoke: () -> Void

    static func == (lhs: EntityCreateCommand, rhs: EntityCreateCommand) -> Bool {
        lhs.options.map(\.id) == rhs.options.map(\.id)
    }
}

extension FocusedValues {
    /// Focused-scene slot for the current detail entity's actions.
    @Entry var entityActions: EntityActions?

    /// Menu-level "new entity" command for the active menu — published by
    /// the entity list (present whenever a menu is selected).
    @Entry var newEntityCommand: EntityCreateCommand?

    /// "Add child" command for the current detail entity — published by the
    /// entity toolbar host (present only when an entity is shown and the
    /// user has expander rights).
    @Entry var addChildCommand: EntityCreateCommand?
}
