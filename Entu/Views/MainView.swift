// Main app layout — switches between two-column and three-column NavigationSplitView:
//   No menu selected AND search empty:  two-column (sidebar + dashboard)
//   Menu selected OR search active:     three-column (sidebar + entity list + detail)
//
// Search text lives in SearchModel (@Observable) so it persists across
// the two/three-column switch. The .searchable modifier sits on the
// Group wrapping both NavigationSplitView instances so the field is
// never destroyed when the layout swaps.

import SwiftUI

/// Column sizing — one source of truth for the split-view modifiers, the
/// hard macOS minimum frames, and the AppStorage defaults (which apply only
/// on first launch, before the user has dragged a divider).
private enum ColumnMetrics {
    static let sidebarMin: Double = 150
    static let sidebarDefault: Double = 225

    static let listMin: Double = 250
    static let listDefault: Double = 375
}

/// Main app layout — two or three-column NavigationSplitView.
struct MainView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    @Environment(AIChatModel.self) private var chat
    @Environment(SessionState.self) private var session
    @Environment(DeepLinkRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var menu: MenuModel?
    @State private var preferredColumn: NavigationSplitViewColumn = .detail

    /// Shared across the two/three-column swap so a collapsed sidebar stays
    /// collapsed.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Bumped by detail-side operations (currently: duplicate) to force
    /// `EntityListView` to refetch its rows even when `query` is unchanged.
    @State private var listRefreshToken: Int = 0

    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = ColumnMetrics.sidebarDefault
    @AppStorage("ui.contentWidth") private var contentWidth: Double = ColumnMetrics.listDefault

    /// Hard column minimums (macOS only — an iPhone screen is narrower than
    /// the list minimum, and compact layouts show one full-width column).
    /// They back up `navigationSplitViewColumnWidth`, which restored window
    /// state can otherwise override with narrower legacy widths.
    #if os(macOS)
    private let sidebarMinWidth: CGFloat? = ColumnMetrics.sidebarMin
    private let listMinWidth: CGFloat? = ColumnMetrics.listMin
    #else
    private let sidebarMinWidth: CGFloat? = nil
    private let listMinWidth: CGFloat? = nil
    #endif

    /// Resolves the selected menu item ID to its API query string.
    private var selectedQuery: String? {
        if let selectedMenuId = session.selectedMenuId, let menu, let query = menu.queryById[selectedMenuId] {
            return query
        }
        return nil
    }

    /// The query passed to EntityListView — an applied advanced search
    /// replaces the menu query (mirroring the webapp's full route-query
    /// replace), otherwise menu selection or empty for global search.
    private var activeQuery: String {
        search.advancedQuery ?? selectedQuery ?? ""
    }

    /// The entity shown in detail — from list selection or history stack navigation.
    private var currentEntityId: String? {
        session.entityHistory.last ?? session.selectedEntityId
    }

    /// Dashboard is shown when no menu item is selected and no search
    /// (text or advanced) is active.
    private var showDashboard: Bool {
        session.selectedMenuId == nil && !search.isActive
    }

    /// Hide the search field on compact-size sidebar (iPhone, iPad split) when no menu is selected.
    /// Matches Mail.app behaviour — search appears on the list view, not the root sidebar.
    private var showSearchField: Bool {
        hSizeClass != .compact || session.selectedMenuId != nil
    }

    /// Binding that resets search, selection, and history in the same tick as the menu change,
    /// so EntityListView observes a consistent (query, search.text) pair on re-render.
    private var menuSelection: Binding<String?> {
        Binding(
            get: { session.selectedMenuId },
            set: { newValue in
                search.text = ""
                search.advancedQuery = nil
                session.selectedEntityId = nil
                session.entityHistory = []
                if newValue != nil {
                    session.pinnedEntityId = nil
                }
                session.selectedMenuId = newValue
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
        search.advancedQuery = nil
        session.clearNavigation()

        if let q = router.pendingQuery["q"], !q.isEmpty {
            search.text = q
        }

        if let menuId = router.pendingQuery["menu"], menu?.queryById[menuId] != nil {
            session.selectedMenuId = menuId
        }

        if let entityId = router.pendingEntityId {
            if session.selectedMenuId == nil {
                // No menu context (e.g. a plugin redirect with no `menu`
                // param) — the two-column layout shows the dashboard unless an
                // entity is *pinned*, so pin it to surface the detail.
                session.pinnedEntityId = entityId
            } else {
                session.entityHistory.append(entityId)
            }
            preferredColumn = .detail
        }

        router.clear()
    }

    /// Applies an advanced-search query — replaces the menu query and search
    /// text, mirroring the webapp's full route-query replace in
    /// `layout/toolbar.vue` `handleAdvancedSearch`. `q` is split off into
    /// `search.text` so the toolbar search field shows and edits it.
    private func applyAdvancedSearch(_ query: [(String, String)]) {
        var query = query
        let q = query.first { $0.0 == "q" }?.1 ?? ""
        query.removeAll { $0.0 == "q" }

        search.text = q
        search.advancedQuery = query.buildURLQuery()
        session.clearNavigation()
        // Guarantees a refetch even when the serialized query is unchanged.
        listRefreshToken &+= 1
    }

    /// Pop the entity history when an entity is deleted while pinned via the
    /// sidebar user row (two-column mode). When history is empty, clear the
    /// pinned entity so the dashboard takes over.
    private func popOrClearPinnedDetail() {
        if !session.entityHistory.isEmpty {
            session.entityHistory.removeLast()
        } else {
            session.pinnedEntityId = nil
        }
    }

    /// Pop the entity history when an entity is deleted while a list row is
    /// selected (three-column mode). When history is empty, clear the
    /// selection so the detail column shows nothing.
    private func popOrClearListDetail() {
        if !session.entityHistory.isEmpty {
            session.entityHistory.removeLast()
        } else {
            session.selectedEntityId = nil
        }
    }

    /// Opens an entity from the sidebar user row. In two-column mode (dashboard visible),
    /// swap the dashboard for the entity detail. In three-column mode, append to the
    /// history stack so it becomes the current detail without clearing menu/search.
    private func openPinnedEntity(_ entityId: String) {
        if showDashboard {
            // No-op if already viewing that exact entity with no sub-navigation.
            if session.pinnedEntityId == entityId && session.entityHistory.isEmpty {
                return
            }
            session.entityHistory = []
            session.pinnedEntityId = entityId
        } else {
            if session.entityHistory.last == entityId {
                return
            }
            session.entityHistory.append(entityId)
        }

        // Push the detail column on compact (iPhone) so NavigationSplitView
        // navigates to the entity instead of staying on the sidebar.
        preferredColumn = .detail
    }

    var body: some View {
        Group {
            if let menu {
                mainContent(menu: menu)
            } else {
                ProgressView()
            }
        }
        .task {
            // Reopen where the user left off *before* the menu loads, so the
            // split view's first render is already in the right (two/three-
            // column, chat open/closed) configuration. Reconfiguring after
            // the first paint mislays the toolbar on macOS. A deep link wins
            // over a saved session, so it's applied after the menu is ready.
            if router.pendingDatabaseId == nil {
                restoreSession(for: api.databaseId)
            }
            let menuModel = MenuModel(api: api)
            menu = menuModel
            await menuModel.load()
            if router.pendingDatabaseId != nil {
                applyPendingDeepLink()
            }
        }
    }

    // MARK: - Session persistence

    /// Save the current "where I left off" state for the active database.
    private func persistSession() {
        session.persist(
            databaseId: api.databaseId,
            searchText: search.text,
            advancedQuery: search.advancedQuery,
            chatOpen: chat.isOpen
        )
    }

    /// Apply the saved session for `databaseId` (nav + search + chat), or
    /// clear to the dashboard when there's none. Wrapped in `withRestoring`
    /// so the side-effect `onChange` handlers don't mangle the restored state.
    private func restoreSession(for databaseId: String?) {
        session.withRestoring {
            if let snapshot = session.snapshot(databaseId: databaseId) {
                session.applyNavigation(snapshot)
                search.text = snapshot.searchText
                search.advancedQuery = snapshot.advancedQuery
                chat.isOpen = snapshot.chatOpen
                if snapshot.entityId != nil || !snapshot.history.isEmpty || snapshot.pinnedId != nil {
                    preferredColumn = .detail
                }
            } else {
                session.clearNavigation()
                search.text = ""
                search.advancedQuery = nil
            }
        }
    }

    /// The two/three-column layout with all cross-cutting modifiers —
    /// extracted from `body` to keep the expression type-checkable.
    private func mainContent(menu: MenuModel) -> some View {
        @Bindable var search = search
        @Bindable var chat = chat

        let layout = Group {
            if showDashboard {
                twoColumnView(menu: menu)
            } else {
                threeColumnView(menu: menu)
            }
        }
        .modifier(MenuScopedSearchable(text: $search.text, enabled: showSearchField))
        .sheet(isPresented: $search.showAdvanced) { advancedSearchSheet }
        .modifier(ChatPresentation(chat: chat, onOpenEntity: openPinnedEntity))
        #if os(macOS)
        // Blank title — the redesign's toolbar carries only the search field;
        // database context lives in the sidebar's bottom user pill. The
        // toolbar background is hidden so the window color runs behind the
        // floating search field instead of a white band.
        .navigationTitle("")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif

        // Split off the event handlers into a second expression — the whole
        // chain otherwise overwhelms the type-checker.
        return stateSync(layout, menu: menu)
    }

    /// Attaches the session-persistence, restore, and cross-cutting reload
    /// handlers to the main layout.
    private func stateSync(_ content: some View, menu: MenuModel) -> some View {
        content
            // A new list selection resets the drill-down history, and a
            // non-empty search clears the pinned entity — but not while
            // restoring a saved session (which sets these together). Each
            // change also persists "where I left off" (`persist` is itself a
            // no-op while restoring).
            .onChange(of: session.selectedEntityId) {
                if !session.isRestoring {
                    session.entityHistory = []
                    // Custom list rows set the selection directly (no
                    // List(selection:) auto-push) — surface the detail
                    // column on compact layouts ourselves.
                    if session.selectedEntityId != nil {
                        preferredColumn = .detail
                    }
                }
                persistSession()
            }
            .onChange(of: search.text) {
                if !session.isRestoring && !search.text.isEmpty { session.pinnedEntityId = nil }
                persistSession()
            }
            .onChange(of: session.selectedMenuId) { persistSession() }
            .onChange(of: session.entityHistory) { persistSession() }
            .onChange(of: session.pinnedEntityId) { persistSession() }
            .onChange(of: search.advancedQuery) { persistSession() }
            .onChange(of: chat.isOpen) { persistSession() }
            .onChange(of: api.databaseId) {
                // AI conversation is account-scoped — clear it on database
                // switch, mirroring the webapp. The account's own saved
                // session (nav + search + chat-open) is then restored, so each
                // database reopens where it was left.
                chat.reset()
                EntityDetailModel.clearCache()
                EntityColorCache.shared.clear()
                restoreSession(for: api.databaseId)
                Task { await menu.load() }
            }
            // An applied AI proposal may have created entity types / entities —
            // reload the menu and force the entity list to refetch.
            .onChange(of: chat.appliedToken) {
                listRefreshToken &+= 1
                Task { await menu.load() }
            }
            .onChange(of: router.pendingDatabaseId) {
                applyPendingDeepLink()
            }
            .onChange(of: auth.isAuthenticated) {
                applyPendingDeepLink()
            }
    }

    // MARK: - Advanced search

    private var advancedSearchSheet: some View {
        NavigationStack {
            SearchSheet(
                currentQuery: activeQuery.parseURLQueryItems(),
                currentText: search.text,
                onSearch: applyAdvancedSearch
            )
        }
        .presentationDetents([.large])
        #if os(macOS)
        // macOS sheets size to content — pin a frame so pushing the
        // entity-type picker (NavigationLink) doesn't collapse the sheet.
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    // MARK: - Two-column: sidebar + dashboard (no menu selected, empty search)

    private func twoColumnView(menu: MenuModel) -> some View {
        @Bindable var session = session
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(selectedMenuId: menuSelection, openPinnedEntity: openPinnedEntity)
                .environment(menu)
                .frame(minWidth: sidebarMinWidth)
                .navigationSplitViewColumnWidth(min: ColumnMetrics.sidebarMin, ideal: max(sidebarWidth, ColumnMetrics.sidebarMin))
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { if $0 != sidebarWidth { sidebarWidth = $0 } }
        } detail: {
            if let pinnedEntityId = session.pinnedEntityId {
                let shownId = session.entityHistory.last ?? pinnedEntityId
                EntityDetailView(
                    entityId: shownId,
                    menuId: session.selectedMenuId,
                    onNavigate: { session.entityHistory.append($0) },
                    onBack: session.entityHistory.isEmpty ? nil : { session.entityHistory.removeLast() },
                    onDelete: { popOrClearPinnedDetail() },
                    onListChanged: { listRefreshToken &+= 1 }
                )
                .entityHistoryBack($session.entityHistory)
            } else {
                DashboardView()
            }
        }
        .environment(menu)
    }

    // MARK: - Three-column: sidebar + entity list + detail (menu selected or search active)

    private func threeColumnView(menu: MenuModel) -> some View {
        @Bindable var session = session
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(selectedMenuId: menuSelection, openPinnedEntity: openPinnedEntity)
                .environment(menu)
                .frame(minWidth: sidebarMinWidth)
                .navigationSplitViewColumnWidth(min: ColumnMetrics.sidebarMin, ideal: max(sidebarWidth, ColumnMetrics.sidebarMin))
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { if $0 != sidebarWidth { sidebarWidth = $0 } }
        } content: {
            EntityListView(
                query: activeQuery,
                menuId: session.selectedMenuId,
                selectedEntityId: $session.selectedEntityId,
                refreshToken: listRefreshToken,
                onOpenAdvancedSearch: { search.showAdvanced = true }
            )
                .frame(minWidth: listMinWidth)
                .navigationSplitViewColumnWidth(min: ColumnMetrics.listMin, ideal: max(contentWidth, ColumnMetrics.listMin))
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { if $0 != contentWidth { contentWidth = $0 } }
        } detail: {
            if let currentEntityId {
                EntityDetailView(
                    entityId: currentEntityId,
                    menuId: session.selectedMenuId,
                    onNavigate: { session.entityHistory.append($0) },
                    onBack: session.entityHistory.isEmpty ? nil : { session.entityHistory.removeLast() },
                    onDelete: { popOrClearListDetail() },
                    onListChanged: { listRefreshToken &+= 1 }
                )
                .entityHistoryBack($session.entityHistory)
            } else {
                // Keeps the detail column alive when no entity is selected.
                Color("WindowBackground").ignoresSafeArea()
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

// MARK: - Chat presentation

/// Docks the Entu AI chat as a trailing panel so it stays open while the user
/// navigates. iOS/iPadOS use `.inspector`; macOS uses a custom column, since
/// `.inspector` fights the window's floating toolbar there.
private struct ChatPresentation: ViewModifier {
    @Bindable var chat: AIChatModel
    let onOpenEntity: (String) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        // A custom trailing column — `.inspector` doesn't coordinate with the
        // window's floating toolbar on macOS. A plain view honors the toolbar's
        // safe-area inset (content sits below it), and a fixed width can't
        // destabilize the split view on resize.
        HStack(spacing: 0) {
            content

            if chat.isOpen {
                Divider()
                AIChatView(onOpenEntity: onOpenEntity)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy, value: chat.isOpen)
        #else
        content.inspector(isPresented: $chat.isOpen) {
            AIChatView(onOpenEntity: onOpenEntity)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        #endif
    }
}

extension View {
    /// While `history` is non-empty, replaces the system back button with
    /// one that pops the history. When the history empties, the system
    /// back returns so the user can dismiss the detail column normally.
    func entityHistoryBack(_ history: Binding<[String]>) -> some View {
        modifier(EntityHistoryBackModifier(history: history))
    }
}

private struct EntityHistoryBackModifier: ViewModifier {
    @Binding var history: [String]

    func body(content: Content) -> some View {
        #if os(macOS)
        // macOS renders the back button as the entity toolbar's first pill
        // (see `EntityToolbar`) — nothing to add here.
        content
        #else
        content
            .navigationBarBackButtonHidden(!history.isEmpty)
            .toolbar {
                if !history.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            history.removeLast()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("back")
                    }
                }
            }
        #endif
    }
}
