import SwiftUI

/// Rights-gated actions for the entity currently shown in the detail
/// column. Published by `EntityToolbarHost` via `.focusedSceneValue` so
/// the File-menu `EntityCommands` (and their keyboard shortcuts) drive
/// the same feature sheets as the toolbar buttons. A `nil` closure means
/// the user lacks the required right — the menu item disables.
struct EntityActions {
    var edit: (() -> Void)?
    var duplicate: (() -> Void)?
    var parents: (() -> Void)?
    var rights: (() -> Void)?
    var history: (() -> Void)?
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
struct EntityCreateCommand {
    let options: [EntityCreateOption]
    let invoke: () -> Void
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
