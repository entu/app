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
    @Environment(CommandPaletteModel.self) private var palette
    @Environment(WindowState.self) private var windowState
    @Environment(WindowSessionStore.self) private var windowSessions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var menu: MenuModel?
    @State private var preferredColumn: NavigationSplitViewColumn = .detail

    /// ⌘F target — programmatic focus for the toolbar search field.
    @FocusState private var searchFieldFocused: Bool

    /// Shared across the two/three-column swap so a collapsed sidebar stays
    /// collapsed.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Bumped by detail-side operations (currently: duplicate) to force
    /// `EntityListView` to refetch its rows even when `query` is unchanged.
    @State private var listRefreshToken: Int = 0

    /// Display name of the entity currently shown in the detail column,
    /// reported by `EntityDetailView`. Feeds the native-tab label (macOS).
    @State private var entityTitle: String = ""

    /// Top safe-area inset (macOS) — the window toolbar's height, and ~36pt
    /// more once the window joins a tab group. Injected into the columns via
    /// `\.windowTopInset` so their top-bleeding headers clear the tab bar
    /// instead of hiding behind it. 52 is the untabbed toolbar height.
    @State private var topInset: CGFloat = 52

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

    #if os(iOS)
    /// Placement decisions use the device idiom, not the size class — an
    /// iPad column can be compact-width yet must keep iPad behavior.
    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
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

    /// Name of the active database — the display name for an authenticated
    /// database, the id itself for a public one (which has no name; the id
    /// doubles as its label, mirroring `AuthModel`).
    private var databaseName: String {
        guard let id = api.databaseId else { return "" }

        return auth.databases.first { $0._id == id }?.name ?? id
    }

    /// Menu label for the selected sidebar item — the same lookup
    /// `EntityListView` shows as the list's title.
    private var menuName: String? {
        guard let menuId = session.selectedMenuId else { return nil }

        return menu?.groups.flatMap(\.items).first { $0._id == menuId }?.name
    }

    /// Native-tab / window label — the open entity's name, else the selected
    /// menu's name (its entity list is shown, mirroring the list title), else
    /// the database name (dashboard).
    private var windowTitle: String {
        let hasEntity = currentEntityId != nil || session.pinnedEntityId != nil
        if hasEntity, !entityTitle.isEmpty {
            return entityTitle
        }

        if let menuName, !menuName.isEmpty {
            return menuName
        }

        return databaseName
    }

    /// Hide the search field on compact-size sidebar (iPhone, iPad split) when no menu is selected.
    /// Matches Mail.app behaviour — search appears on the list view, not the root sidebar.
    private var showSearchField: Bool {
        horizontalSizeClass != .compact || session.selectedMenuId != nil || search.isActive
    }

    /// Binding that resets search, selection, and history in the same tick as the menu change,
    /// so EntityListView observes a consistent (query, search.text) pair on re-render.
    private var menuSelection: Binding<String?> {
        Binding(
            get: { session.selectedMenuId },
            set: { newValue in
                // The sidebar's List re-asserts the current selection when
                // the sidebar (re)appears — a no-op write must not clear
                // search/navigation or slam the compact column shut (it
                // made the iPhone sidebar toggle look dead).
                guard newValue != session.selectedMenuId else { return }

                // ⌘-click a sidebar menu item → open it in a new tab/window
                // instead of switching this window's selection.
                if interceptsMenuToNewTab(newValue) { return }

                search.text = ""
                search.advancedQuery = nil
                session.selectedEntityId = nil
                session.entityHistory = []
                if newValue != nil {
                    session.pinnedEntityId = nil
                }
                session.selectedMenuId = newValue

                #if os(iOS)
                // iPhone: close the sidebar on selection. In landscape
                // (regular width) it overlays the list and would stay
                // floating on top; iPad keeps its persistent sidebar.
                if newValue != nil, isPhone {
                    columnVisibility = .doubleColumn
                    preferredColumn = .content
                }
                #endif
            }
        )
    }

    // MARK: - Open in new tab / window

    /// Open `id` in a new window. On macOS the system tabs it next to the
    /// current tab (per the user's "Prefer tabs" setting); on iPad it's a
    /// new scene window.
    private func openEntityInNewTab(_ id: String) {
        openWindow(id: "main", value: TabRequest(content: .entity(id)))
    }

    /// ⌘-click routing — when the Command key is held at click time, open the
    /// entity in a new tab/window instead and report the click as consumed.
    /// Every entity-link click funnels through one of three roots
    /// (`openPinnedEntity`, `navigate(to:)`, `entitySelection`), so this is
    /// checked only there — leaf views stay modifier-unaware.
    private func interceptsToNewTab(_ id: String?) -> Bool {
        guard supportsMultipleWindows, let id, ModifierState.isCommandHeld else { return false }

        openEntityInNewTab(id)
        return true
    }

    /// ⌘-click routing for a sidebar menu item — opens that menu's entity
    /// list in a new tab/window instead of switching this window.
    private func interceptsMenuToNewTab(_ menuId: String?) -> Bool {
        guard supportsMultipleWindows, let menuId, ModifierState.isCommandHeld else { return false }

        openWindow(id: "main", value: TabRequest(content: .menu(menuId)))
        return true
    }

    /// Detail-side navigation (reference chips, parent/type chips, table
    /// rows) — pushes onto the history stack unless ⌘-click routes it to a
    /// new tab.
    private func navigate(to entityId: String) {
        if interceptsToNewTab(entityId) { return }

        session.entityHistory.append(entityId)
    }

    /// List-selection binding — intercepts ⌘-click into a new tab (keeping
    /// the current selection), otherwise writes through to the session.
    private var entitySelection: Binding<String?> {
        Binding(
            get: { session.selectedEntityId },
            set: { newValue in
                if newValue != session.selectedEntityId, interceptsToNewTab(newValue) { return }

                session.selectedEntityId = newValue
            }
        )
    }

    /// Apply a pending deep link from `DeepLinkRouter`. Switches the database
    /// if needed, resets navigation state, optionally pre-fills search/menu
    /// from query params, then opens the linked entity (if any). Cleared
    /// once consumed so the same link doesn't re-fire. With several windows
    /// open, only the window whose URL handler received the link consumes it.
    ///
    /// Resolves the target database in this order:
    ///   1. authenticated database — `selectDatabase`
    ///   2. saved public database — `selectPublicDatabase`
    ///   3. unknown database — probe for public access; on success add it to
    ///      the saved list and select. On failure clear the pending state and
    ///      stay where we are.
    private func applyPendingDeepLink() {
        guard router.targetWindowId == nil || router.targetWindowId == windowState.windowId else { return }
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
        // Keep the selected menu — `activeQuery` prefers the advanced query
        // for the list anyway, and dropping the menu would also hide the
        // menu-scoped Add button and (on iPhone) the search field.
        session.selectedEntityId = nil
        session.entityHistory = []
        session.pinnedEntityId = nil
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

    /// Palette "Go to Dashboard" — clear menu selection, search, and
    /// navigation so the two-column dashboard layout takes over.
    private func goToDashboard() {
        search.text = ""
        search.advancedQuery = nil
        session.clearNavigation()
    }

    /// Opens an entity from the sidebar user row, the command palette, or an
    /// AI-chat link. In two-column mode (dashboard visible), swap the
    /// dashboard for the entity detail. In three-column mode, append to the
    /// history stack so it becomes the current detail without clearing menu/search.
    private func openPinnedEntity(_ entityId: String) {
        if interceptsToNewTab(entityId) { return }

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
            // Apply this window's initial state *before* the menu loads, so
            // the split view's first render is already in the right (two/
            // three-column, chat open/closed) configuration. Reconfiguring
            // after the first paint mislays the toolbar on macOS. A deep
            // link wins over a saved session, so it's applied after the menu
            // is ready. `hasRestored` skips the restore when the language-
            // change `.id` rebuild re-runs this task — the per-window models
            // already hold the live state.
            if router.pendingDatabaseId == nil, !windowState.hasRestored {
                applyInitialState()
            }
            windowState.hasRestored = true
            // Register this window in the store even if nothing changes after
            // restore, so it's persisted for the next launch.
            updateWindowSession()
            let menuModel = MenuModel(api: api)
            menu = menuModel
            await menuModel.load()
            if router.pendingDatabaseId != nil {
                applyPendingDeepLink()
            }
        }
        // View > Clear Cache (⇧⌘R) — see `ReloadCommands`.
        .focusedSceneValue(\.clearCacheCommand, ClearCacheCommand { hardReset() })
    }

    /// ⇧⌘R — drop every local cache and UI setting (credentials and the
    /// in-app language survive), reset the in-memory session, and land on
    /// the database dashboard. The menu refetch rides the `logOutToken`
    /// bump `clearLocalData` makes (see `stateSync`), in this window and
    /// every other one.
    private func hardReset() {
        auth.clearLocalData()
        // Land on the dashboard — on iPhone the sidebar may be the shown
        // compact column, so switch back to detail explicitly.
        preferredColumn = .detail
    }

    // MARK: - Session persistence

    /// Save the current "where I left off" state — both the per-database
    /// `ui.session` store (database switch, cold start, single-window
    /// fallback) and this window's entry in the ordered `WindowSessionStore`
    /// (per-tab relaunch restore).
    private func persistSession() {
        session.persist(
            databaseId: api.databaseId,
            searchText: search.text,
            advancedQuery: search.advancedQuery,
            chatOpen: chat.isOpen
        )
        updateWindowSession()
    }

    /// Register/refresh this window's snapshot in the ordered store.
    private func updateWindowSession() {
        guard let databaseId = api.databaseId else { return }

        windowSessions.update(
            windowState.windowId,
            snapshot: SessionState.SceneSnapshot(
                databaseId: databaseId,
                epoch: SessionState.currentEpoch,
                snapshot: session.currentSnapshot(
                    searchText: search.text,
                    advancedQuery: search.advancedQuery,
                    chatOpen: chat.isOpen
                )
            )
        )
    }

    /// First-appearance state for this window. Precedence:
    /// 1. The window's own restored scene snapshot (relaunch), if it still
    ///    matches the active database.
    /// 2. The seed it was opened with — ⌘T dashboard or ⌘-click entity,
    ///    both starting from clean navigation and search.
    /// 3. The per-database saved session (default window, cold start).
    private func applyInitialState() {
        // Restored windows carry the default `.restore` seed — claim the
        // next saved per-window snapshot in order (only when it belongs to
        // the active database and the current sign-out epoch, so a previous
        // user's snapshot is never applied).
        if case .restore = windowState.seed,
           let claimed = windowSessions.claim(),
           claimed.databaseId == api.databaseId,
           claimed.epoch == SessionState.currentEpoch {
            applySnapshot(claimed.snapshot)
            return
        }

        switch windowState.seed {
        case .dashboard:
            applySnapshot(nil)
        case .entity(let entityId):
            var snapshot = SessionState.Snapshot()
            snapshot.pinnedId = entityId
            applySnapshot(snapshot)
        case .menu(let menuId):
            var snapshot = SessionState.Snapshot()
            snapshot.menuId = menuId
            applySnapshot(snapshot)
        case .restore:
            restoreSession(for: api.databaseId)
        }
    }

    /// Apply the saved session for `databaseId` (nav + search + chat), or
    /// clear to the dashboard when there's none.
    private func restoreSession(for databaseId: String?) {
        applySnapshot(session.snapshot(databaseId: databaseId))
    }

    /// Apply `snapshot` (nav + search + chat), or clear to the dashboard
    /// when nil. Wrapped in `withRestoring` so the side-effect `onChange`
    /// handlers don't mangle the restored state.
    private func applySnapshot(_ snapshot: SessionState.Snapshot?) {
        session.withRestoring {
            if let snapshot {
                session.applyNavigation(snapshot)
                search.text = snapshot.searchText
                search.advancedQuery = snapshot.advancedQuery
                chat.isOpen = snapshot.chatOpen
                // Compact (iPhone) shows exactly one column — pick the one
                // matching the restored state: open entity → detail; a menu
                // or search without an entity → the list (the three-column
                // layout's detail is a blank placeholder until a row is
                // picked); otherwise the dashboard (detail of two-column).
                if snapshot.entityId != nil || !snapshot.history.isEmpty || snapshot.pinnedId != nil {
                    preferredColumn = .detail
                } else if snapshot.menuId != nil || !snapshot.searchText.isEmpty || snapshot.advancedQuery != nil {
                    preferredColumn = .content
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

        // Row context menus offer "open in new tab/window" wherever the
        // platform supports multiple windows (nil hides the item on iPhone).
        // Typed out here — an inline ternary overwhelms the type-checker.
        let openInNewTab: ((String) -> Void)? = supportsMultipleWindows
            ? { openEntityInNewTab($0) }
            : nil

        let layout = Group {
            if showDashboard {
                twoColumnView(menu: menu)
            } else {
                threeColumnView(menu: menu)
            }
        }
        .modifier(MenuScopedSearchable(text: $search.text, focused: $searchFieldFocused, enabled: showSearchField))
        .sheet(isPresented: $search.showAdvanced) { advancedSearchSheet }
        .modifier(ChatPresentation(chat: chat, onOpenEntity: openPinnedEntity))
        #if os(macOS)
        // Blank title — the redesign's toolbar carries only the search field;
        // database context lives in the sidebar's bottom user pill. The
        // toolbar background is hidden so the window color runs behind the
        // floating search field instead of a white band.
        .navigationTitle("")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The window's top inset grows by the tab-bar height when tabbed —
        // captured here (where the toolbar establishes it) and fed to the
        // columns so their top-bleeding headers clear the tab bar.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { newInset in
            if newInset > 0 { topInset = newInset }
        }
        #endif

        // Split off the event handlers into a second expression — the whole
        // chain otherwise overwhelms the type-checker.
        return ZStack {
            stateSync(layout, menu: menu)

            // ⌘K command palette — floats over the whole split view.
            if palette.isOpen {
                CommandPaletteView(
                    onOpenEntity: openPinnedEntity,
                    onSelectMenu: { menuSelection.wrappedValue = $0 },
                    onGoDashboard: goToDashboard,
                    onApplyQuery: applyAdvancedSearch
                )
                .environment(menu)
                .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.15), value: palette.isOpen)
        .environment(\.openEntityInNewTab, openInNewTab)
        .environment(\.windowTopInset, topInset)
        #if os(macOS)
        // Label this window's native tab — the redesign keeps the window
        // title empty, so without this the tab shows no name. `initial`
        // seeds it at first render; the `macWindow` didSet re-applies once
        // the accessor hands over the window.
        .onChange(of: windowTitle, initial: true) { windowState.tabTitle = windowTitle }
        #endif
        // View > Command Palette (⌘K) — see `PaletteCommands`.
        .focusedSceneValue(\.commandPalette, CommandPaletteToggle {
            palette.toggle(databaseId: api.databaseId)
        })
        // Edit > Search (⌘F) — see `SearchFieldCommands`. Same modal
        // guard as the palette: the field would gain focus behind a sheet.
        .focusedSceneValue(\.focusSearch, FocusSearchCommand {
            guard palette.modalDepth == 0 else { return }

            palette.close()
            searchFieldFocused = true
        })
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
                palette.close()
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
            // ⇧⌘R in *another* window cleared the menu cache and this
            // window's navigation (via `WindowRootView`) — refetch the menu
            // so this window doesn't keep serving the stale in-memory copy.
            // Sign-out also bumps the token, but then `api.databaseId` is
            // already nil and `MainView` is on its way out.
            .onChange(of: auth.logOutToken) {
                guard api.databaseId != nil else { return }

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
            AdvancedSearchSheet(
                currentQuery: activeQuery.parseURLQueryItems(),
                currentText: search.text,
                onSearch: applyAdvancedSearch
            )
        }
        .blocksCommandPalette()
        // Wider page-sheet sizing on iPad, same as the edit and Rights
        // sheets.
        .presentationSizing(.page)
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
            sidebarColumn(menu: menu)
        } detail: {
            if let pinnedEntityId = session.pinnedEntityId {
                let shownId = session.entityHistory.last ?? pinnedEntityId
                EntityDetailView(
                    entityId: shownId,
                    menuId: session.selectedMenuId,
                    onNavigate: { navigate(to: $0) },
                    onBack: session.entityHistory.isEmpty ? nil : { session.entityHistory.removeLast() },
                    onDelete: { popOrClearPinnedDetail() },
                    onListChanged: { listRefreshToken &+= 1 },
                    onTitle: { entityTitle = $0 }
                )
                .entityHistoryBack($session.entityHistory)
            } else {
                DashboardView()
                    #if os(iOS)
                    // iPhone: the split view collapses to a stack and would
                    // show a back chevron to the sidebar — replace it with
                    // a sidebar toggle so the stats view reads as the root.
                    .navigationBarBackButtonHidden(horizontalSizeClass == .compact)
                    .toolbar {
                        if horizontalSizeClass == .compact {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    preferredColumn = .sidebar
                                } label: {
                                    Label("menu", systemImage: "sidebar.left")
                                }
                            }
                        }
                    }
                    #endif
            }
        }
        .environment(menu)
    }

    /// Sidebar toggle for a *pushed* compact column — pops the navigation
    /// stack (same as the hidden back button would) and also updates the
    /// preferred column so the split view's state stays in sync.
    private struct CompactSidebarToggle: View {
        @Environment(\.dismiss) private var dismiss

        let setPreferred: () -> Void

        var body: some View {
            Button {
                setPreferred()
                dismiss()
            } label: {
                Label("menu", systemImage: "sidebar.left")
            }
        }
    }

    /// Shared sidebar column for both split layouts. On iPhone it carries
    /// a toggle back to the detail column (stats), mirroring the
    /// dashboard's own sidebar toggle.
    private func sidebarColumn(menu: MenuModel) -> some View {
        SidebarView(selectedMenuId: menuSelection, openPinnedEntity: openPinnedEntity)
            .environment(menu)
            .frame(minWidth: sidebarMinWidth)
            .navigationSplitViewColumnWidth(min: ColumnMetrics.sidebarMin, ideal: max(sidebarWidth, ColumnMetrics.sidebarMin))
            .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { if $0 != sidebarWidth { sidebarWidth = $0 } }
            #if os(iOS)
            .toolbar {
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            preferredColumn = .detail
                        } label: {
                            Label("menu", systemImage: "sidebar.left")
                        }
                    }
                }
            }
            #endif
    }

    // MARK: - Three-column: sidebar + entity list + detail (menu selected or search active)

    private func threeColumnView(menu: MenuModel) -> some View {
        @Bindable var session = session
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            sidebarColumn(menu: menu)
        } content: {
            EntityListView(
                query: activeQuery,
                menuId: session.selectedMenuId,
                selectedEntityId: entitySelection,
                refreshToken: listRefreshToken,
                onOpenAdvancedSearch: { search.showAdvanced = true }
            )
                .frame(minWidth: listMinWidth)
                .navigationSplitViewColumnWidth(min: ColumnMetrics.listMin, ideal: max(contentWidth, ColumnMetrics.listMin))
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { if $0 != contentWidth { contentWidth = $0 } }
                #if os(iOS)
                // iPhone portrait: the compact stack would show a back
                // chevron to the sidebar — use the sidebar toggle instead,
                // same as the dashboard. The list is a pushed stack entry
                // here, so the toggle pops it (`dismiss`) — flipping
                // `preferredColumn` alone doesn't pop a pushed column.
                .navigationBarBackButtonHidden(horizontalSizeClass == .compact)
                .toolbar {
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarLeading) {
                            CompactSidebarToggle {
                                preferredColumn = .sidebar
                            }
                        }
                    }
                }
                #endif
        } detail: {
            if let currentEntityId {
                EntityDetailView(
                    entityId: currentEntityId,
                    menuId: session.selectedMenuId,
                    onNavigate: { navigate(to: $0) },
                    onBack: session.entityHistory.isEmpty ? nil : { session.entityHistory.removeLast() },
                    onDelete: { popOrClearListDetail() },
                    onListChanged: { listRefreshToken &+= 1 },
                    onTitle: { entityTitle = $0 }
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
    var focused: FocusState<Bool>.Binding
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, prompt: "search")
                .searchFocused(focused)
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

    /// Persisted panel width, like the sidebar and list columns.
    @AppStorage("ui.chatWidth") private var chatWidth: Double = 300

    /// Width at drag start — deltas apply against it so the drag doesn't
    /// compound.
    @State private var dragBaseWidth: Double?

    /// No max — same policy as the sidebar and list columns.
    private static let minWidth: Double = 260

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
                    .frame(width: chatWidth)
                    // Invisible grab strip on the panel's leading edge —
                    // drag to resize, persisted via ui.chatWidth.
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(
                                // Global space — the handle itself moves as
                                // the panel resizes, so local translations
                                // feed back into the drag and jitter.
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let base = dragBaseWidth ?? chatWidth
                                        dragBaseWidth = base
                                        chatWidth = max(base - value.translation.width, Self.minWidth)
                                    }
                                    .onEnded { _ in dragBaseWidth = nil }
                            )
                    }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy, value: chat.isOpen)
        #else
        content.inspector(isPresented: $chat.isOpen) {
            AIChatView(onOpenEntity: onOpenEntity)
                .inspectorColumnWidth(min: Self.minWidth, ideal: chatWidth)
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: {
                    if $0 != chatWidth { chatWidth = $0 }
                }
        }
        #endif
    }
}

extension EnvironmentValues {
    /// Window top safe-area inset (macOS) — the toolbar height plus the tab
    /// bar when the window is tabbed. The top-bleeding column headers
    /// (entity-list count strip, entity-detail band) size their clearance
    /// from it so they sit below the tab bar instead of behind it. Default is
    /// the untabbed toolbar height; `MainView` overrides it live.
    @Entry var windowTopInset: CGFloat = 52
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
