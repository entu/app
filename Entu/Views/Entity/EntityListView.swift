import SwiftUI

/// Scrollable entity list with search, infinite scroll, and pull-to-refresh.
struct EntityListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    @Environment(MenuModel.self) private var menu
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

    /// Opens the advanced-search sheet (owned by `MainView`). iOS/iPadOS
    /// only — on macOS the button lives in the window toolbar instead.
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

    /// Hardware keyboard arrow-key navigation. SwiftUI's `List(selection:)`
    /// moves selection on Up/Down once it has focus — we just need to
    /// surrender focus to it on appear. Mirrors webapp's `onKeyStroke`
    /// in `layout/entity-list.vue`.
    @FocusState private var isListFocused: Bool

    /// Captured during a create-mode commit, surfaced after the sheet
    /// dismisses — same deferred-close pattern as `EntityToolbarHost`.
    /// Calling `pendingCreate = nil` from inside `onSaved` would
    /// dismiss the sheet on the very first autosave; users want to
    /// keep typing into other fields before closing.
    @State private var pendingCreatedId: String?

    private var hasMore: Bool { items.count < totalCount }

    var body: some View {
        List(selection: $selectedEntityId) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    EntityAvatar(name: item.name, entityId: item._id, hasPhoto: item.hasPhoto)
                    Text(item.name).lineLimit(1)
                }
                .tag(item._id)
                .onAppear {
                    if item.id == items.last?.id && hasMore && !isLoadingMore {
                        Task { await loadMore() }
                    }
                }
            }

            if isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if !hasMore && totalCount > 0 {
                Text("\(totalCount)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .clipped()
        .focused($isListFocused)
        .refreshable { await loadEntities() }
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
            // is attached — focused state on a List is invisible on touch.
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
        #if os(iOS)
        .toolbar { advancedSearchToolbarContent }
        #endif
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
            .presentationDetents([.large])
        }
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
    /// `<entity-toolbar-add>` in `entity/toolbar.vue` — visible whenever
    /// the active menu has any types declaring it as an `add_from`.
    /// Single type: direct button with the type label. Multiple: a Menu.
    @ToolbarContentBuilder
    private var addToolbarContent: some ToolbarContent {
        // Hidden when an entity is open — the entity detail toolbar
        // renders the same Add button there to avoid visual duplication.
        // Also hidden in public-database mode (no authenticated user) —
        // creating top-level entities requires write access, which a
        // read-only public session never has.
        if auth.currentUserId != nil,
           selectedEntityId == nil,
           let menuId,
           let types = menu.addFromTypes[menuId],
           !types.isEmpty {
            ToolbarItem(placement: .primaryAction) {
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
        }
    }

    #if os(iOS)
    /// Advanced-search button next to the list. Mirrors the webapp's
    /// advanced-search toolbar button — hidden in public-database mode
    /// (webapp gates the whole search UI on a signed-in user).
    @ToolbarContentBuilder
    private var advancedSearchToolbarContent: some ToolbarContent {
        if SearchModel.showAdvancedButton, auth.currentUserId != nil, let onOpenAdvancedSearch {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onOpenAdvancedSearch()
                } label: {
                    Label(
                        "advancedSearch",
                        systemImage: search.advancedQuery != nil
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
            }
        }
    }
    #endif

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
