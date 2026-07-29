// Auxiliary entity window — dedicated to a single entity, the app's
// counterpart of Mail's message window (HIG "Windows": an auxiliary window
// "presents a specific task or area… dedicated to one experience"). Shows
// only the entity detail — no sidebar, no list — so there is no navigation
// chrome to hide and no per-tab sidebar state to manage (macOS syncs
// sidebar visibility across a native tab group by design, see
// CLAUDE-APP.md). Opened by double-click, ⌘-click, ⌘O, and "Open in New
// Window" on any entity row, via the `windowID` WindowGroup; windows of
// this group tab together — never with main windows (own WindowGroup =
// own tabbing identifier) — per the user's system "Prefer tabs" setting.
// Reopening the same entity fronts its existing window (equal WindowGroup
// values), like Mail.

import SwiftUI

struct EntityWindowRootView: View {
    /// The entity WindowGroup's scene id — target of every
    /// `openWindow(id:value:)` that opens an entity window.
    static let windowID = "entity"

    @Environment(AuthModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private let api: APIClient

    /// The window's root entity — the WindowGroup value.
    let entityId: String

    /// Per-window models the detail stack (toolbar host, sheets, edit
    /// view) reads from the environment — same roles as `WindowRootView`.
    @State private var windowState: WindowState
    @State private var search = SearchModel()
    @State private var palette = CommandPaletteModel()
    @State private var menu: MenuModel

    /// Drill-down history within this window (reference chips, child
    /// rows); the shown entity is the last entry — the window's root
    /// entity when empty.
    @State private var history: [String] = []

    /// Loaded entity's display name — labels the window's native tab.
    @State private var entityTitle = ""

    /// In-app language — re-keys the content below so every
    /// `LocalizedStringKey` re-resolves on change (see `EntuApp`).
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    init(api: APIClient, entityId: String) {
        self.api = api
        self.entityId = entityId
        // `@State` init-in-init only takes effect on first construction —
        // the models must survive later re-inits of the view.
        _windowState = State(initialValue: WindowState(seed: .entity(entityId)))
        _menu = State(initialValue: MenuModel(api: api))
    }

    private var shownId: String { history.last ?? entityId }

    var body: some View {
        NavigationStack {
            EntityDetailView(
                entityId: shownId,
                onNavigate: { navigate(to: $0) },
                onBack: history.isEmpty ? nil : { history.removeLast() },
                onDelete: { popOrClose() },
                onTitle: { entityTitle = $0 }
            )
            .entityHistoryBack($history)
        }
        // ⌘-click on references / child rows inside this window opens yet
        // another entity window.
        .environment(\.openEntityInNewWindow, OpenEntityInNewWindowAction { openEntityWindow($0) })
        .environment(menu)
        .environment(search)
        .environment(palette)
        .environment(windowState)
        .id(appLanguage)
        // Same window chrome as the main window: blank title (the entity's
        // colored band runs behind the transparent toolbar), tab labeled
        // with the entity name.
        .windowTabChrome(title: entityTitle)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
        .task {
            // A window restored while signed out / with no database
            // selected has nothing to show — close it instead of
            // rendering an error state. The id-shape check covers the one
            // id source nothing else validates — the persisted scene value
            // (deep links validate in `DeepLinkRouter`, API-returned ids
            // are server-owned) — so a tampered snapshot can't put an
            // arbitrary path segment into the entity request.
            guard api.databaseId != nil,
                  entityId.count == 24, entityId.allSatisfy(\.isHexDigit) else {
                dismiss()
                return
            }

            await menu.load()
        }
        // The entity belongs to the active database — close the window on
        // sign-out and on database switch, so nothing of the previous
        // context stays on screen.
        .onChange(of: auth.logOutToken) { dismiss() }
        .onChange(of: api.databaseId) { dismiss() }
    }

    private func openEntityWindow(_ entityId: String) {
        openWindow(id: Self.windowID, value: entityId)
    }

    /// Reference / child-row navigation — pushes onto this window's
    /// history; ⌘-click opens another entity window instead, same
    /// interception as `MainView.navigate(to:)`.
    private func navigate(to entityId: String) {
        if supportsMultipleWindows && ModifierState.isCommandHeld {
            openEntityWindow(entityId)
            return
        }

        history.append(entityId)
    }

    /// After a delete: pop back within the window, or close it when the
    /// root entity is gone (Mail closes a message window the same way).
    private func popOrClose() {
        if history.isEmpty {
            dismiss()
        } else {
            history.removeLast()
        }
    }
}
