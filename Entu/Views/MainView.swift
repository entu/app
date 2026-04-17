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
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var menu: MenuModel?
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var selectedMenuId: String?
    @State private var selectedEntityId: String?
    @State private var entityHistory: [String] = []
    @State private var showDbPicker = false

    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = 220
    @AppStorage("ui.contentWidth") private var contentWidth: Double = 320

    private var currentDatabase: Database? {
        auth.databases.first { $0._id == api.databaseId }
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
                selectedMenuId = newValue
            }
        )
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
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showDbPicker.toggle()
                        } label: {
                            Image(systemName: "cylinder.split.1x2")
                        }
                        .sheet(isPresented: $showDbPicker) {
                            DatabaseListView(showCloseButton: true)
                        }
                    }
                }
                #endif
                .onChange(of: selectedEntityId) {
                    entityHistory = []
                }
                .onChange(of: api.databaseId) {
                    selectedMenuId = nil
                    selectedEntityId = nil
                    entityHistory = []
                    search.text = ""
                    EntityDetailModel.clearCache()
                    Task { await menu.load() }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let menuModel = MenuModel(api: api)
            menu = menuModel
            await menuModel.load()
        }
    }

    // MARK: - Two-column: sidebar + dashboard (no menu selected, empty search)

    private func twoColumnView(menu: MenuModel) -> some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            SidebarView(selectedMenuId: menuSelection)
                .environment(menu)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 400)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { sidebarWidth = $0 }
        } detail: {
            DashboardView()
        }
        .environment(menu)
    }

    // MARK: - Three-column: sidebar + entity list + detail (menu selected or search active)

    private func threeColumnView(menu: MenuModel) -> some View {
        NavigationSplitView {
            SidebarView(selectedMenuId: menuSelection)
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
            content.searchable(text: $text, prompt: String(localized: "search"))
        } else {
            content
        }
    }
}
