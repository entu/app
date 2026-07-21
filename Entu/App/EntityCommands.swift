// Menu-bar command groups — File > New (entity / child / window) and the
// View-menu reload commands. All driven by focused values published from
// the on-screen views, so shortcuts track the current context and rights.

import SwiftUI

/// File > New section — create commands for entities and children, plus the
/// New Window affordance. Replaces the default `.newItem` group so ⌘N
/// creates an entity (the app's primary object, like New Note in Notes)
/// rather than a window; New Window moves to ⇧⌘N so the window-reopen
/// affordance App Review requires still exists.
///
/// Commands come from focused values published by the entity list
/// (`newEntityCommand`) and the entity toolbar host (`addChildCommand`), so
/// the commands and their rights gating track the on-screen context. When
/// a menu has one add type, the shortcut creates it directly and the item
/// reads "New <Type>". With several types the item reads "New…" and the
/// shortcut opens a keyboard-navigable type chooser.
///
/// The shortcut is always on a plain `Button`, never on a `Menu`: UIKit
/// (iPad) propagates a `Menu`'s key equivalent to every child item, so a
/// submenu of types would register the same shortcut once per type and
/// crash with "Replacement elements contain duplicates."
///
/// Menu-bar strings resolve against the system language (plain
/// `String(localized:)`, not `.currentLocalized`) — the OS has no Estonian
/// localization, so following the in-app language toggle would leave a
/// mixed-language menu bar.
struct NewEntityCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @FocusedValue(\.newEntityCommand) private var newEntityCommand
    @FocusedValue(\.addChildCommand) private var addChildCommand

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            newEntitySection
            addChildSection
            // New Window is available wherever the platform offers multiple
            // windows (macOS always, iPad with Stage Manager / Split View;
            // never iPhone). New Tab is macOS-only — iPadOS has no window
            // tabs; ⌘-click on entity links opens scene windows there. macOS
            // tabs the ⌘T window itself (per the user's "Prefer tabs"
            // setting), next to the current tab — no manual attaching.
            // `.newWindow` (not the default `.restore`) so an explicit new
            // window never claims a launch-restored window's snapshot.
            if supportsMultipleWindows {
                Divider()
                Button(String(localized: "menuNewWindow")) {
                    openWindow(value: TabRequest(content: .newWindow))
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                #if os(macOS)
                Button(String(localized: "menuNewTab")) {
                    openWindow(value: TabRequest(content: .dashboard))
                }
                .keyboardShortcut("t")
                #endif
            }
        }
    }

    /// New entity (⌘N). One type → a direct "New <Type>" item; several →
    /// a "New…" item whose shortcut opens the chooser.
    @ViewBuilder
    private var newEntitySection: some View {
        if let command = newEntityCommand, let first = command.options.first {
            let title = command.options.count == 1
                ? String(localized: "menuNew \(first.menuLabel)")
                : String(localized: "menuNewMulti")
            Button(title) { command.invoke() }
                .keyboardShortcut("n")
        }
    }

    /// Add child (⌃⌘N) — only when the detail entity has addable child types
    /// and the user has expander rights. Same single-vs-chooser shape as
    /// `newEntitySection`.
    @ViewBuilder
    private var addChildSection: some View {
        if let command = addChildCommand, let first = command.options.first {
            let title = command.options.count == 1
                ? String(localized: "menuAddChild \(first.menuLabel)")
                : String(localized: "menuAddChildMulti")
            Button(title) { command.invoke() }
                .keyboardShortcut("n", modifiers: [.command, .control])
        }
    }
}

/// Database menu — authenticated databases first (no group title), then
/// public, then a Browse-public entry. Always shown so the user can add a
/// public database from the menu bar even before signing in. The Browse
/// entry rides the `browsePublicDatabase` focused scene value so the entry
/// alert presents in the active window only (an app-level binding would
/// present it in every window at once).
///
/// Menu-bar strings resolve against the system language (plain
/// `String(localized:)`, not `.currentLocalized`) — see `NewEntityCommands`.
struct DatabaseCommands: Commands {
    let auth: AuthModel
    let api: APIClient

    @FocusedValue(\.browsePublicDatabase) private var browsePublicDatabase

    var body: some Commands {
        CommandMenu(String(localized: "database")) {
            ForEach(auth.databases) { database in
                Toggle(database.name, isOn: Binding(
                    get: { database._id == api.databaseId },
                    set: { if $0 { auth.selectDatabase(database) } }
                ))
            }

            if !auth.publicDatabases.isEmpty {
                Section(String(localized: "publicDatabasesSection")) {
                    ForEach(auth.publicDatabases, id: \.self) { id in
                        Toggle(id, isOn: Binding(
                            get: { id == api.databaseId },
                            set: { if $0 { auth.selectPublicDatabase(id) } }
                        ))
                    }
                }
            }

            if auth.isAuthenticated || !auth.publicDatabases.isEmpty {
                Divider()
            }

            Button {
                browsePublicDatabase?.invoke()
            } label: {
                Text(String(localized: "browsePublicDatabaseMenu"))
            }
        }
    }
}

/// View > Command Palette (⌘K) — toggles the palette overlay. Driven by
/// the `commandPalette` focused scene value `MainView` publishes, the
/// same mechanism as the entity actions, so the shortcut registers
/// identically on macOS and iPadOS. Deliberately NOT `.disabled` when
/// the value is absent — iPadOS hides disabled menu items entirely
/// (dropping the item and its ⌘K glyph from the menu); outside the
/// main view the button is simply a no-op.
///
/// Menu-bar strings resolve against the system language (plain
/// `String(localized:)`, not `.currentLocalized`) — see `EntityCommands`.
struct PaletteCommands: Commands {
    @FocusedValue(\.commandPalette) private var commandPalette

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button {
                commandPalette?.invoke()
            } label: {
                Text(String(localized: "menuCommandPalette"))
            }
            .keyboardShortcut("k")
        }
    }
}

/// Edit > Search (⌘F) — focuses the toolbar search field. Same focused
/// scene-value mechanism (and iPadOS not-disabled rationale) as
/// `PaletteCommands`.
struct SearchFieldCommands: Commands {
    @FocusedValue(\.focusSearch) private var focusSearch

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button {
                focusSearch?.invoke()
            } label: {
                Text(String(localized: "search"))
            }
            .keyboardShortcut("f")
        }
    }
}

/// View-menu reload commands. ⌘R refetches the shown entity and its type
/// from the API (bypassing the type cache); ⇧⌘R is the hard variant — it
/// drops every local cache and UI setting (credentials survive) and returns
/// to the database dashboard. Shortcuts follow the browser reload / hard-
/// reload convention.
///
/// Menu-bar strings resolve against the system language (plain
/// `String(localized:)`, not `.currentLocalized`) — see `EntityCommands`.
struct ReloadCommands: Commands {
    @FocusedValue(\.entityActions) private var actions
    @FocusedValue(\.clearCacheCommand) private var clearCache
    @FocusedValue(\.reloadListCommand) private var reloadList

    /// ⌘R action — an open entity's reload (which also refetches the list)
    /// wins; with only the list visible, the list refetch runs alone.
    private func reload() {
        if let reload = actions?.reload {
            reload()
        } else {
            reloadList?.invoke()
        }
    }

    private var reloadDisabled: Bool {
        actions?.reload == nil && reloadList == nil
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            #if os(macOS)
            // One menu slot: "Reload Entity" swaps to "Clear Cache and
            // Reload" while ⇧ is held (standard macOS alternate item).
            Button(String(localized: "menuReloadEntity")) {
                reload()
            }
            .keyboardShortcut("r")
            .disabled(reloadDisabled)
            .modifierKeyAlternate(.shift) {
                Button(String(localized: "menuClearCache")) {
                    clearCache?.invoke()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(clearCache == nil)
            }
            #else
            // iPadOS keyboard menus don't support modifier alternates —
            // both items stay visible.
            Button(String(localized: "menuReloadEntity")) {
                reload()
            }
            .keyboardShortcut("r")
            .disabled(reloadDisabled)

            Button(String(localized: "menuClearCache")) {
                clearCache?.invoke()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(clearCache == nil)
            #endif
        }
    }
}

/// Entity actions in the File menu — Edit / Duplicate / Parents / Rights /
/// History for the entity currently shown in the detail column. Entities
/// are the app's document-like objects, so their actions live in File per
/// the HIG (like File > Duplicate in document apps). Mirrors
/// `EntityToolbar`'s buttons and rights gating through the `entityActions`
/// focused value: items disable when no entity is shown or the user lacks
/// the right. Shows in the macOS menu bar and the iPadOS hardware-keyboard
/// menu, and carries the keyboard shortcuts on both.
///
/// Menu-bar strings resolve against the system language (plain
/// `String(localized:)`, not `.currentLocalized`) — the OS has no Estonian
/// localization, so following the in-app language toggle would leave a
/// mixed-language menu bar.
struct EntityCommands: Commands {
    @FocusedValue(\.entityActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            Button(String(localized: "edit")) {
                actions?.edit?()
            }
            .keyboardShortcut("e")
            .disabled(actions?.edit == nil)

            Button(String(localized: "duplicate")) {
                actions?.duplicate?()
            }
            .keyboardShortcut("d")
            .disabled(actions?.duplicate == nil)

            Button(String(localized: "parents")) {
                actions?.parents?()
            }
            .disabled(actions?.parents == nil)

            Divider()

            // Cmd-I follows the macOS "Get Info" convention; Cmd-Y is the
            // browser-style History shortcut.
            Button(String(localized: "rights")) {
                actions?.rights?()
            }
            .keyboardShortcut("i")
            .disabled(actions?.rights == nil)

            Button(String(localized: "history")) {
                actions?.history?()
            }
            .keyboardShortcut("y")
            .disabled(actions?.history == nil)

            Divider()

            // ⌥⌘O — open the shown entity in a new tab (macOS) / window
            // (iPad). Absent (nil) on iPhone; disabled with no entity open.
            #if os(macOS)
            let openLabel = String(localized: "openInNewTab")
            #else
            let openLabel = String(localized: "openInNewWindow")
            #endif
            Button(openLabel) {
                actions?.openInNewTab?()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(actions?.openInNewTab == nil)
        }
    }
}
