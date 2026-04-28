// Main app layout — switches between two-column and three-column NavigationSplitView:
//   No menu selected AND search empty:  two-column (sidebar + dashboard)
//   Menu selected OR search active:     three-column (sidebar + entity list + detail)
//
// Search text lives in SearchModel (@Observable) so it persists across
// the two/three-column switch. The .searchable modifier sits on the
// Group wrapping both NavigationSplitView instances so the field is
// never destroyed when the layout swaps.

import SwiftUI

/// Main app layout — two or three-column NavigationSplitView.
struct MainView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    @Environment(DeepLinkRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var menu: MenuModel?
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedMenuId: String?
    @State private var selectedEntityId: String?
    @State private var entityHistory: [String] = []
    @State private var pinnedEntityId: String?

    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = 220
    @AppStorage("ui.contentWidth") private var contentWidth: Double = 320

    private var currentDatabase: Database? {
        if let authenticated = auth.databases.first(where: { $0._id == api.databaseId }) {
            return authenticated
        }
        // Public databases have no name/user info from the API — synthesize a
        // Database value from the id so the macOS subtitle can show something.
        if let id = api.databaseId, auth.publicDatabases.contains(id) {
            return Database(_id: id, name: id, user: nil)
        }
        return nil
    }

    /// Resolves the selected menu item ID to its API query string.
    private var selectedQuery: String? {
        if let selectedMenuId, let menu, let query = menu.queryById[selectedMenuId] {
            return query
        }
        return nil
    }

    /// The query passed to EntityListView — from menu selection or empty for global search.
    private var activeQuery: String {
        selectedQuery ?? ""
    }

    /// The entity shown in detail — from list selection or history stack navigation.
    private var currentEntityId: String? {
        entityHistory.last ?? selectedEntityId
    }

    /// Dashboard is shown when no menu item is selected and the search field is empty.
    private var showDashboard: Bool {
        selectedMenuId == nil && search.text.isEmpty
    }

    /// Hide the search field on compact-size sidebar (iPhone, iPad split) when no menu is selected.
    /// Matches Mail.app behaviour — search appears on the list view, not the root sidebar.
    private var showSearchField: Bool {
        hSizeClass != .compact || selectedMenuId != nil
    }

    /// Binding that resets search, selection, and history in the same tick as the menu change,
    /// so EntityListView observes a consistent (query, search.text) pair on re-render.
    private var menuSelection: Binding<String?> {
        Binding(
            get: { selectedMenuId },
            set: { newValue in
                search.text = ""
                selectedEntityId = nil
                entityHistory = []
                if newValue != nil {
                    pinnedEntityId = nil
                }
                selectedMenuId = newValue
            }
        )
    }

    /// Apply a pending deep link from `DeepLinkRouter`. Switches the database
    /// if needed, resets navigation state, optionally pre-fills search/menu
    /// from query params, then opens the linked entity (if any). Cleared
    /// once consumed so the same link doesn't re-fire.
    ///
    /// Resolves the target database in this order:
    ///   1. authenticated database — `selectDatabase`
    ///   2. saved public database — `selectPublicDatabase`
    ///   3. unknown database — probe for public access; on success add it to
    ///      the saved list and select. On failure clear the pending state and
    ///      stay where we are.
    private func applyPendingDeepLink() {
        guard let dbId = router.pendingDatabaseId else { return }

        if dbId != api.databaseId {
            if let target = auth.databases.first(where: { $0._id == dbId }) {
                auth.selectDatabase(target)
            } else if auth.publicDatabases.contains(dbId) {
                auth.selectPublicDatabase(dbId)
            } else {
                Task { await bootstrapPublicDeepLink(dbId: dbId) }
                return
            }
        }

        consumePendingDeepLink()
    }

    /// Probe an unknown database from a deep link and add it as public on success.
    private func bootstrapPublicDeepLink(dbId: String) async {
        let result = (try? await api.probePublicDatabase(dbId)) ?? .notFound
        guard result == .found else {
            router.clear()
            return
        }
        auth.addPublicDatabase(dbId)
        auth.selectPublicDatabase(dbId)
        consumePendingDeepLink()
    }

    /// Apply the pending search/menu/entity state and clear the router.
    private func consumePendingDeepLink() {
        search.text = ""
        selectedEntityId = nil
        entityHistory = []
        pinnedEntityId = nil
        selectedMenuId = nil

        if let q = router.pendingQuery["q"], !q.isEmpty {
            search.text = q
        }

        if let menuId = router.pendingQuery["menu"], menu?.queryById[menuId] != nil {
            selectedMenuId = menuId
        }

        if let entityId = router.pendingEntityId {
            entityHistory.append(entityId)
            preferredColumn = .detail
        }

        router.clear()
    }

    /// Opens an entity from the sidebar user row. In two-column mode (dashboard visible),
    /// swap the dashboard for the entity detail. In three-column mode, append to the
    /// history stack so it becomes the current detail without clearing menu/search.
    private func openPinnedEntity(_ entityId: String) {
        if showDashboard {
            // No-op if already viewing that exact entity with no sub-navigation.
            if pinnedEntityId == entityId && entityHistory.isEmpty {
                return
            }
            entityHistory = []
            pinnedEntityId = entityId
        } else {
            if entityHistory.last == entityId {
                return
            }
            entityHistory.append(entityId)
        }

        // Push the detail column on compact (iPhone) so NavigationSplitView
        // navigates to the entity instead of staying on the sidebar.
        preferredColumn = .detail
    }

    var body: some View {
        @Bindable var search = search

        Group {
            if let menu {
                Group {
                    if showDashboard {
                        twoColumnView(menu: menu)
                    } else {
                        threeColumnView(menu: menu)
                    }
                }
                .modifier(MenuScopedSearchable(text: $search.text, enabled: showSearchField))
                #if os(macOS)
                .navigationTitle("Entu")
                .navigationSubtitle(currentDatabase?.name ?? "")
                #endif
                .onChange(of: selectedEntityId) {
                    entityHistory = []
                }
                .onChange(of: search.text) {
                    if !search.text.isEmpty {
                        pinnedEntityId = nil
                    }
                }
                .onChange(of: api.databaseId) {
                    selectedMenuId = nil
                    selectedEntityId = nil
                    entityHistory = []
                    pinnedEntityId = nil
                    search.text = ""
                    EntityDetailModel.clearCache()
                    Task { await menu.load() }
                }
                .onChange(of: router.pendingDatabaseId) {
                    applyPendingDeepLink()
                }
                .onChange(of: auth.isAuthenticated) {
                    applyPendingDeepLink()
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let menuModel = MenuModel(api: api)
            menu = menuModel
            await menuModel.load()
            applyPendingDeepLink()
        }
    }

    // MARK: - Two-column: sidebar + dashboard (no menu selected, empty search)

    private func twoColumnView(menu: MenuModel) -> some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            SidebarView(selectedMenuId: menuSelection, openPinnedEntity: openPinnedEntity)
                .environment(menu)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 400)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarWidth = $0 }
        } detail: {
            if let pinnedEntityId {
                let shownId = entityHistory.last ?? pinnedEntityId
                EntityDetailView(entityId: shownId) { entityId in
                    entityHistory.append(entityId)
                }
                .toolbar {
                    if !entityHistory.isEmpty {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                entityHistory.removeLast()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .accessibilityLabel("back")
                        }
                    }
                }
            } else {
                DashboardView()
            }
        }
        .environment(menu)
    }

    // MARK: - Three-column: sidebar + entity list + detail (menu selected or search active)

    private func threeColumnView(menu: MenuModel) -> some View {
        NavigationSplitView {
            SidebarView(selectedMenuId: menuSelection, openPinnedEntity: openPinnedEntity)
                .environment(menu)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 400)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarWidth = $0 }
        } content: {
            EntityListView(query: activeQuery, selectedEntityId: $selectedEntityId)
                .navigationSplitViewColumnWidth(min: 240, ideal: contentWidth, max: 600)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { contentWidth = $0 }
        } detail: {
            if let currentEntityId {
                EntityDetailView(entityId: currentEntityId) { entityId in
                    entityHistory.append(entityId)
                }
                .toolbar {
                    if !entityHistory.isEmpty {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                entityHistory.removeLast()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .accessibilityLabel("back")
                        }
                    }
                }
            }
        }
        .environment(menu)
    }
}

// MARK: - Conditional searchable

/// Applies `.searchable` only when enabled — the modifier stays anchored to the
/// same view, never moves, just disappears on the iPhone sidebar.
private struct MenuScopedSearchable: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "search")
        } else {
            content
        }
    }
}
