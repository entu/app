// Focused-value commands — the rights-gated entity actions and the
// create / reload / clear-cache commands the menu bar consumes, with the
// FocusedValues slots they publish through.

import SwiftUI

/// Rights-gated actions for the entity currently shown in the detail
/// column. Published by `EntityToolbarHost` via `.focusedSceneValue` so
/// the File-menu `EntityCommands` (and their keyboard shortcuts) drive
/// the same feature sheets as the toolbar buttons. A `nil` closure means
/// the user lacks the required right — the menu item disables.
///
/// `Equatable` on the entity identity plus the *availability* of each
/// action (not the closures, which change every render): lets SwiftUI
/// dedupe the focused-value updates so a burst of re-renders during
/// entity load doesn't republish many times per frame (which merely
/// warns on macOS but can freeze iPad). Identity is part of the equality
/// so navigating between entities with identical rights still
/// republishes — fresh closures for the new entity.
struct EntityActions: Equatable {
    /// Identity of the entity the closures act on — the command palette
    /// titles its actions section with "type · name".
    var entityId: String?
    var entityName: String?
    var entityTypeLabel: String?

    var edit: (() -> Void)?
    var duplicate: (() -> Void)?
    var parents: (() -> Void)?
    var rights: (() -> Void)?
    var history: (() -> Void)?
    var reload: (() -> Void)?

    static func == (lhs: EntityActions, rhs: EntityActions) -> Bool {
        lhs.entityId == rhs.entityId
            && lhs.entityName == rhs.entityName
            && lhs.entityTypeLabel == rhs.entityTypeLabel
            && (lhs.edit == nil) == (rhs.edit == nil)
            && (lhs.duplicate == nil) == (rhs.duplicate == nil)
            && (lhs.parents == nil) == (rhs.parents == nil)
            && (lhs.rights == nil) == (rhs.rights == nil)
            && (lhs.history == nil) == (rhs.history == nil)
            && (lhs.reload == nil) == (rhs.reload == nil)
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

/// View-menu "clear cache" command (⇧⌘R) published by `MainView`. Always
/// equal — its availability never changes while the main view is up, so
/// SwiftUI dedupes the focused-value republishes (see `EntityActions`).
struct ClearCacheCommand: Equatable {
    let invoke: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// Edit-menu "find" command (⌘F) published by `MainView` — moves focus
/// into the toolbar search field. Always equal (see `ClearCacheCommand`).
struct FocusSearchCommand: Equatable {
    let invoke: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// View-menu "command palette" toggle (⌘K) published by `MainView` —
/// same focused-value mechanism as the entity actions, so the shortcut
/// registers identically on macOS and iPadOS. Always equal (see
/// `ClearCacheCommand`).
struct CommandPaletteToggle: Equatable {
    let invoke: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// ⌘R fallback published by `EntityListView`: refetches the list when no
/// entity is shown (an open entity's `EntityActions.reload` wins and
/// reloads both). Equality compares `context` (the list's query), NOT the
/// closure: SwiftUI drops republishes of equal focused values, so an
/// always-equal command would freeze the first closure — and its captured
/// query — forever, making ⌘R reload a long-gone list.
struct ReloadListCommand: Equatable {
    let context: String
    let invoke: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context
    }
}

extension FocusedValues {
    /// Focused-scene slot for the current detail entity's actions.
    @Entry var entityActions: EntityActions?

    /// Clear-every-cache command — published by `MainView`.
    @Entry var clearCacheCommand: ClearCacheCommand?

    /// Command-palette toggle (⌘K) — published by `MainView`.
    @Entry var commandPalette: CommandPaletteToggle?

    /// Focus-the-search-field command (⌘F) — published by `MainView`.
    @Entry var focusSearch: FocusSearchCommand?

    /// List-refetch command — published by `EntityListView`.
    @Entry var reloadListCommand: ReloadListCommand?

    /// Menu-level "new entity" command for the active menu — published by
    /// the entity list (present whenever a menu is selected).
    @Entry var newEntityCommand: EntityCreateCommand?

    /// "Add child" command for the current detail entity — published by the
    /// entity toolbar host (present only when an entity is shown and the
    /// user has expander rights).
    @Entry var addChildCommand: EntityCreateCommand?
}
