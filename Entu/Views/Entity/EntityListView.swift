// Entity list column — search, infinite scroll, pull-to-refresh, and
// derived-color row selection. iPhone moves filter · search · New into
// the bottom bar; macOS/iPad keep them in the top toolbar.

import SwiftUI

/// Scrollable entity list with search, infinite scroll, and pull-to-refresh.
/// Custom rows instead of `List(selection:)` — the selected row is tinted
/// with the entity's derived color (rounded fill + ring), which the system
/// list highlight cannot do. Arrow-key selection is reimplemented via
/// `onKeyPress` on the focused scroll container.
struct EntityListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    @Environment(MenuModel.self) private var menu
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    let query: String

    /// ID of the currently-selected menu entity, used to look up which
    /// types can be added under it (`menu.addFromTypes`). Nil while the
    /// list is showing a global search result rather than a menu.
    let menuId: String?

    /// Selection binding — drives the detail column in `NavigationSplitView`.
    @Binding var selectedEntityId: String?

    /// Bumped from outside to force a list refetch — used after duplicate
    /// (and other operations that change the visible row set without
    /// changing `query`). Plumbed through `MainView` → `EntityDetailView` →
    /// `EntityToolbarHost`'s `onListChanged`.
    var refreshToken: Int = 0

    /// Window-space x-origin of this column. When the sidebar is collapsed
    /// the list becomes the leftmost column — on macOS the window controls
    /// + sidebar toggle then sit over it and the header shifts right to
    /// clear them; on all platforms it means the sidebar isn't there to
    /// show which menu is active, so the menu label becomes the title.
    /// Measured instead of derived from the split view's visibility so it
    /// can't go stale.
    @State private var columnOriginX: CGFloat = .infinity

    /// The active menu's label — nil while the list shows a global search
    /// result rather than a menu.
    private var menuLabel: String? {
        guard let menuId else { return nil }

        return menu.groups.flatMap(\.items).first { $0._id == menuId }?.name
    }

    /// Menu label as title with the count demoted to subtitle — only when
    /// the collapsed sidebar can't show which menu is active, and advanced
    /// search isn't narrowing the rows beyond the menu's own query.
    private var showsMenuTitle: Bool {
        search.advancedQuery == nil && columnOriginX < 50 && menuLabel != nil
    }

    /// Opens the advanced-search sheet (owned by `MainView`) — wired to the
    /// round button in the list header on all platforms.
    var onOpenAdvancedSearch: (() -> Void)? = nil

    @State private var items: [EntityListItem] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var pageSize = 50
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var pendingCreate: EntityEditMode?

    /// Presents the type chooser when ⌘N fires and the active menu has
    /// more than one addable type. `pendingNewType` holds the chosen type
    /// until the picker dismisses, then opens the editor for it.
    @State private var showNewTypePicker = false
    @State private var pendingNewType: EntityCreateOption?

    /// Hardware keyboard arrow-key navigation over the custom rows.
    /// Focus is handed to the scroll container on appear; Up/Down move the
    /// selection. Mirrors webapp's `onKeyStroke` in `layout/entity-list.vue`.
    @FocusState private var isListFocused: Bool

    /// Captured during a create-mode commit, surfaced after the sheet
    /// dismisses — same deferred-close pattern as `EntityToolbarHost`.
    /// Calling `pendingCreate = nil` from inside `onSaved` would
    /// dismiss the sheet on the very first autosave; users want to
    /// keep typing into other fields before closing.
    @State private var pendingCreatedId: String?

    private var hasMore: Bool { items.count < totalCount }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Count on the toolbar line — the column ignores the top safe
            // area so the text occupies the strip the (hidden-background)
            // window toolbar floats over. Text only: the strip belongs to
            // the window (drag region), so nothing interactive lives here —
            // the advanced-search button is a real toolbar item instead.
            HStack {
                if showsMenuTitle, let menuLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: menuLabel)
                            .font(.headline)
                            .lineLimit(1)

                        Text("entityCount \(totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .opacity(isLoading && items.isEmpty ? 0 : 1)
                    }
                } else {
                    countTitle
                }
                Spacer()
            }
            .padding(.leading, columnOriginX < 50 ? 150 : 16)
            .padding(.trailing, 16)
            // The strip matches the window-toolbar height, content centered
            // vertically — both the single-line count and the stacked
            // title+count sit on the toolbar's optical line.
            .frame(height: 52)
            // Bar material behind the title — rows scrolling up would
            // otherwise show through it.
            .background(.bar)
            .zIndex(1)
            #endif

            listRows
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minX
        } action: { columnOriginX = $0 }
        #if os(macOS)
        .ignoresSafeArea(edges: .top)
        .toolbar {
            if auth.currentUserId != nil, let onOpenAdvancedSearch {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onOpenAdvancedSearch()
                    } label: {
                        advancedSearchLabel
                    }
                }
            }
        }
        #else
        // iOS: inline navigation title — an in-column header under the nav
        // bar would leave a double strip of empty space. Menu label + count
        // subtitle when the sidebar is hidden (see `showsMenuTitle`), the
        // bare count otherwise.
        .navigationTitle(showsMenuTitle ? Text(verbatim: menuLabel ?? "") : Text("entityCount \(totalCount)"))
        .navigationSubtitle(showsMenuTitle ? Text("entityCount \(totalCount)") : Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iPhone bottom bar, Mail/Notes-style: filter · search · New.
            // The filter is declared before the search item so it sits
            // leading; New (`addToolbarContent`) follows trailing.
            if auth.currentUserId != nil, let onOpenAdvancedSearch {
                ToolbarItem(placement: isPhone ? .bottomBar : .topBarTrailing) {
                    Button {
                        onOpenAdvancedSearch()
                    } label: {
                        Label("advancedSearch", systemImage: "line.3.horizontal.decrease")
                    }
                    // iOS toolbar buttons ignore the label's foreground
                    // style — tint the button itself when filtering.
                    .tint(search.advancedQuery != nil ? Color.accentColor : nil)
                }
            }

            // Custom bottom-bar items would evict the docked search field
            // to the top — explicitly keep it in the bottom bar. Fixed
            // spacers split the glass groups so filter / search / New stay
            // individual capsules, in Mail/Notes order: filter · search ·
            // New. New must be declared HERE (after the search item) —
            // in its own `.toolbar` block it would group with the filter.
            if isPhone {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)

                if let types = availableAddTypes {
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        addButton(types: types)
                    }
                }
            }
        }
        #endif
        .overlay {
            if isLoading && items.isEmpty {
                EntityRowsPlaceholder(count: 8)
            } else if !isLoading && items.isEmpty {
                ContentUnavailableView {
                    Label("noResults", systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: query) {
            items = []
            totalCount = 0
            await loadEntities()
            // Hand focus to the list so arrow keys move selection without
            // requiring a click first. Harmless when no hardware keyboard
            // is attached — focused state is invisible on touch.
            isListFocused = true
        }
        .onChange(of: refreshToken) {
            // Outside-driven refresh (e.g. after duplicate) — keep the
            // existing rows visible while reloading so the user doesn't
            // see a flash to empty.
            Task { await loadEntities() }
        }
        .onChange(of: search.text) {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                items = []
                totalCount = 0
                await loadEntities()
            }
        }
        .toolbar { addToolbarContent }
        // File > New (⌘N) — same menu-level add types and create-sheet state
        // as the toolbar's Add button. Present whenever a menu is selected,
        // so ⌘N works from the list and while an entity is open.
        .focusedSceneValue(\.newEntityCommand, newEntityCommand)
        // View > Reload Entity (⌘R) fallback while no entity is open —
        // refetches the list rows. Keeps existing rows visible (same
        // no-flash behavior as the `refreshToken` path).
        .focusedSceneValue(\.reloadListCommand, ReloadListCommand(context: query) {
            Task { await loadEntities() }
        })
        // ⌘N with several addable types opens this chooser (the toolbar's
        // Add menu can't be opened programmatically). Title matches the
        // create window's header (`titleAddBare`) so the picker and the
        // editor it opens read the same. The chosen type's create runs on
        // dismiss so the editor sheet doesn't present while the picker is
        // still closing.
        .sheet(isPresented: $showNewTypePicker, onDismiss: {
            if let option = pendingNewType {
                pendingNewType = nil
                option.create()
            }
        }) {
            TypePickerSheet(title: "titleAddBare", options: newEntityOptions) { chosen in
                pendingNewType = chosen
            }
        }
        .sheet(
            item: $pendingCreate,
            onDismiss: {
                if let id = pendingCreatedId {
                    selectedEntityId = id
                    Task { await loadEntities() }
                }
                pendingCreatedId = nil
            }
        ) { mode in
            NavigationStack {
                EntityEditView(mode: mode) { newId in
                    pendingCreatedId = newId
                }
            }
            // Wider page-sheet sizing on iPad (same as Rights) — the
            // two-column rows need the room.
            .presentationSizing(.page)
        }
    }

    // MARK: - Header (count + advanced search)

    private var countTitle: some View {
        Text("entityCount \(totalCount)")
            .font(.headline)
            .monospacedDigit()
            .opacity(isLoading && items.isEmpty ? 0 : 1)
    }

    /// Touch platforms get taller rows (≈44pt targets); macOS stays
    /// compact. iPhone gets extra breathing room — its narrow single
    /// column reads denser than the iPad's list column.
    private var rowVerticalPadding: CGFloat {
        #if os(macOS)
        5
        #else
        horizontalSizeClass == .compact ? 14 : 10
        #endif
    }

    // MARK: - Rows

    private var listRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        row(item)
                            .id(item._id)
                            .onAppear {
                                if item.id == items.last?.id && hasMore && !isLoadingMore {
                                    Task { await loadMore() }
                                }
                            }
                    }

                    if isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .refreshable { await loadEntities() }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            #if os(macOS)
            // onMoveCommand instead of onKeyPress — onKeyPress handlers can
            // go stale on macOS between focus changes, resuming from the
            // selection they last saw instead of the current one.
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(-1, proxy: proxy)
                case .down: moveSelection(1, proxy: proxy)
                default: break
                }
            }
            #else
            .onKeyPress(.upArrow) {
                moveSelection(-1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(1, proxy: proxy)
                return .handled
            }
            #endif
        }
    }

    /// Filter icon — accent-tinted while an advanced search is applied,
    /// so the active filter is visible at a glance.
    @ViewBuilder
    private var advancedSearchLabel: some View {
        if search.advancedQuery != nil {
            Label("advancedSearch", systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(Color.accentColor)
        } else {
            Label("advancedSearch", systemImage: "line.3.horizontal.decrease")
        }
    }

    private func row(_ item: EntityListItem) -> some View {
        let isSelected = selectedEntityId == item._id

        return Button {
            selectedEntityId = item._id
            // Keep keyboard focus on the list so the next arrow press moves
            // from this row, not from wherever the keyboard last was.
            isListFocused = true
        } label: {
            HStack(spacing: 9) {
                EntityAvatar(name: item.name, entityId: item._id, hasPhoto: item.hasPhoto, size: 24)

                Text(item.name)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.entityTintText(for: item._id)) : AnyShapeStyle(.primary))

                Spacer(minLength: 0)
            }
            .padding(.vertical, rowVerticalPadding)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.entityTintFill(for: item._id))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.entityTintBorder(for: item._id), lineWidth: 1)
                        }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Right-click (macOS) / long-press (iPad, iPhone) — the entity
        // actions, mirroring the toolbar. The action selects the row and
        // runs once the detail has loaded, with the same rights gating.
        .entityRowContextMenu(entityId: item._id) {
            selectedEntityId = item._id
        }
    }

    /// Move the selection by `delta` rows and keep it visible.
    private func moveSelection(_ delta: Int, proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }

        let currentIndex = items.firstIndex { $0._id == selectedEntityId }
        let fallback = delta > 0 ? -1 : 0
        let newIndex = min(max((currentIndex ?? fallback) + delta, 0), items.count - 1)

        selectedEntityId = items[newIndex]._id
        proxy.scrollTo(items[newIndex]._id)
    }

    // MARK: - New-entity command

    /// Menu-level "new entity" options — one per addable type in the active
    /// menu, each opening the create sheet. Same guard as `addToolbarContent`.
    private var newEntityOptions: [EntityCreateOption] {
        guard auth.currentUserId != nil,
              let menuId,
              let types = menu.addFromTypes[menuId] else { return [] }

        return types.map { type in
            EntityCreateOption(id: type._id, label: type.label, menuLabel: type.englishLabel) {
                pendingCreate = .create(parentId: nil, typeId: type._id, typeLabel: type.label)
            }
        }
    }

    /// File > New (⌘N) command. `nil` (not empty) when unavailable so the
    /// menu item disappears. One type → the shortcut creates it directly;
    /// several → it opens the type chooser below.
    private var newEntityCommand: EntityCreateCommand? {
        let options = newEntityOptions
        guard !options.isEmpty else { return nil }

        return EntityCreateCommand(options: options) {
            if options.count == 1 {
                options[0].create()
            } else {
                showNewTypePicker = true
            }
        }
    }

    // MARK: - Add toolbar

    /// Menu-level Add button. Mirrors the webapp's left-most
    /// Addable types for the New button, or nil when it must not show:
    /// hidden while an entity is open (the detail toolbar has its own Add),
    /// and in read-only public-database mode.
    private var availableAddTypes: [AddFromType]? {
        guard auth.currentUserId != nil,
              selectedEntityId == nil,
              let menuId,
              let types = menu.addFromTypes[menuId],
              !types.isEmpty else { return nil }

        return types
    }

    /// The New button/menu — shared between the iPad/macOS top toolbar and
    /// the iPhone bottom bar.
    @ViewBuilder
    private func addButton(types: [AddFromType]) -> some View {
        if types.count == 1, let only = types.first {
            Button {
                pendingCreate = .create(parentId: nil, typeId: only._id, typeLabel: only.label)
            } label: {
                Label {
                    Text("addOne \(only.label.lowercased())")
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
            }
        } else {
            Menu {
                ForEach(types) { type in
                    Button(type.label.lowercased()) {
                        pendingCreate = .create(parentId: nil, typeId: type._id, typeLabel: type.label)
                    }
                }
            } label: {
                Label("add", systemImage: "square.and.pencil")
            }
        }
    }

    /// `<entity-toolbar-add>` in `entity/toolbar.vue` — visible whenever
    /// the active menu has any types declaring it as an `add_from`.
    /// Single type: direct button with the type label. Multiple: a Menu.
    /// On iPhone (compact) the button lives in the bottom bar instead —
    /// declared next to the search item so the order stays filter ·
    /// search · New.
    @ToolbarContentBuilder
    private var addToolbarContent: some ToolbarContent {
        if let types = availableAddTypes, !isPhone {
            ToolbarItem(placement: .primaryAction) {
                addButton(types: types)
            }
        }
    }

    /// True on iPhone — placement decisions use the device idiom, NOT the
    /// size class: an iPad's list column is narrow enough to report
    /// compact, but its toolbar buttons belong on top.
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    // MARK: - Data loading

    /// Fetch the first page of entities from the API.
    private func loadEntities() async {
        isLoading = true
        var params = query.parseURLQuery()
        params["props"] = "photo,name"
        params["limit"] = String(pageSize)
        params["skip"] = "0"
        if !search.text.isEmpty { params["q"] = search.text }

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            items = response.entities.map { EntityListItem(from: $0) }
            totalCount = response.count ?? 0
        }
        isLoading = false
    }

    /// Fetch the next page of entities (infinite scroll).
    private func loadMore() async {
        isLoadingMore = true
        var params = query.parseURLQuery()
        params["props"] = "photo,name"
        params["limit"] = String(pageSize)
        params["skip"] = String(items.count)
        if !search.text.isEmpty { params["q"] = search.text }

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            items.append(contentsOf: response.entities.map { EntityListItem(from: $0) })
            totalCount = response.count ?? totalCount
        }
        isLoadingMore = false
    }
}
