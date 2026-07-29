// Full-width table for the main entity list — the app's counterpart of
// webapp's `entity/table.vue`, shown instead of the list+detail split
// while the list/table toggle (`ui.showTable`) is on. Columns are
// auto-detected from the returned entities (name first, then the union of
// non-system property names, each typed by its first non-empty value);
// header taps sort server-side (`sort=field.type` / `-field.type`);
// scrolling loads more (same infinite scroll as the list). Selecting a row
// arms the entity actions (invisible toolbar host); opening happens via
// double-click / ⌘-click / context menu into the auxiliary entity window.

import SwiftUI

/// Auto-detected column — property name doubles as the header label,
/// mirroring webapp's raw `{{ column.name }}` headers.
/// Internal (not private) so the `+PadTable` companion file can use it.
struct MainTableColumn: Identifiable, Equatable {
    let name: String
    let type: String

    var id: String { name }

    /// Bridge to the shared cell renderer's column model.
    var asTableColumn: EntityTableColumn {
        EntityTableColumn(name: name, label: name, type: type, decimals: nil)
    }
}

/// Sort plumbing for the native `Table` — carries the clicked column;
/// never compares (ordering is server-side, the sort change refetches).
private struct EntityColumnComparator: SortComparator {
    let column: String
    var order: SortOrder = .forward

    func compare(_ lhs: EntitySummary, _ rhs: EntitySummary) -> ComparisonResult { .orderedSame }
}

/// Sortable, infinitely-scrolling table over the active main-list query.
/// State and helpers the `+PadTable` companion file reads are internal
/// rather than private (extensions in other files can't see private).
struct MainEntityTable: View {
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    @Environment(\.locale) private var locale
    @Environment(\.openEntityInNewWindow) var openEntityInNewWindow
    #if os(macOS)
    @Environment(\.windowTabBarInset) private var windowTabBarInset
    #endif

    let query: String

    /// Active menu id — forwarded to the entity toolbar host so the
    /// menu-level Add button works for the selected row's context.
    var menuId: String?

    /// Outside-driven refresh (an entity was edited/deleted elsewhere).
    let refreshToken: Int

    var onOpenAdvancedSearch: (() -> Void)?

    // MARK: - Selection

    /// Selected row. Selecting doesn't open the entity — it arms the
    /// entity actions: once the entity loads, the invisible
    /// `entityToolbarHost` below publishes the toolbar pills, the
    /// menu-bar commands/shortcuts (Edit, Rights, …), and consumes the
    /// row context menu's pending action — same machinery as the list.
    @State var selection: String?

    /// Loads the selected row's `EntityDetail` for the toolbar host
    /// (rights gating needs the loaded entity).
    @State private var detailModel: EntityDetailModel?

    /// Create sheet for the no-selection New button (with a selection the
    /// entity toolbar host provides New). Same deferred-select pattern as
    /// `EntityListView`'s create flow.
    @State private var pendingCreate: EntityEditMode?
    @State private var pendingCreatedId: String?

    @State var entities: [EntitySummary] = []
    @State private var totalCount = 0
    @State var sortColumn: String?
    /// Captured when the sort is chosen — `columns` derives from the
    /// loaded entities, so resolving the type at request time would see
    /// a stale/empty column set and fall back to `string` for dates,
    /// numbers, etc.
    @State private var sortColumnType = "string"
    @State var sortAscending = true
    @State private var isLoading = false
    @State var isLoadingMore = false
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Property-definition labels for the active query's entity type —
    /// headers show these instead of the raw property names. Empty when
    /// the query names no single type (free search) or a property has no
    /// label; headers then fall back to the name (webapp behavior).
    @State var columnLabels: [String: String] = [:]

    /// Property-definition ordinals, from the same fetch — columns order
    /// by these (undefined properties go last, alphabetically).
    @State private var columnOrdinals: [String: Double] = [:]

    private static let pageSize = 50

    #if os(macOS)
    /// Leading edge of this column in window coordinates. Near 0 the table
    /// is the leftmost column (sidebar collapsed) and the window controls +
    /// sidebar toggle sit over the count strip — the title then shifts
    /// right to clear them. Measured instead of derived from the split
    /// view's visibility so it can't go stale (same as `EntityListView`).
    @State private var columnOriginX: CGFloat = .infinity
    #endif

    var hasMore: Bool { entities.count < totalCount }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Count on the toolbar strip — same construction as
            // `EntityListView`'s macOS header (text only; the strip is the
            // window's drag region, interactive controls are toolbar items).
            HStack {
                Text("entityCount \(totalCount)")
                    .font(.headline)
                    .monospacedDigit()
                    .opacity(isLoading && entities.isEmpty ? 0 : 1)
                Spacer()
            }
            // With the sidebar collapsed the table is the leftmost column —
            // the title shifts right to clear the window controls (same
            // measured pattern as `EntityListView`'s header).
            .headerStripPadding(columnOriginX: columnOriginX)
            // The strip matches the window-toolbar height; a native tab
            // bar adds to the top inset — pad downward so the table
            // starts under it, not behind it (same as `EntityListView`).
            .frame(height: 52)
            .padding(.bottom, windowTabBarInset)
            .background(.bar)
            .zIndex(1)
            #endif

            tableBody
                // Placeholder / empty state over the table area only —
                // top-aligned below the Table's own column-header row
                // (an unpadded overlay would draw across it).
                .overlay(alignment: .top) {
                    if isLoading && entities.isEmpty {
                        EntityRowsPlaceholder(count: 8)
                            .padding(.top, 32)
                    }
                }
                .overlay {
                    if !isLoading && entities.isEmpty {
                        ContentUnavailableView {
                            Label("noResults", systemImage: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        #if os(macOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minX
        } action: { columnOriginX = $0 }
        .ignoresSafeArea(edges: .top)
        #else
        .navigationTitle(Text("entityCount \(totalCount)"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // One builder for deterministic order — New (own pill) · then
            // the toggle · filter group (separately-attached blocks jump
            // leading, separate conditional items interleave
            // unpredictably). New shows without a selection only — with a
            // row selected the entity toolbar host carries its own New.
            if selection == nil {
                ToolbarItem(placement: .primaryAction) {
                    MenuLevelAddButton(menuId: menuId) { type in
                        pendingCreate = .create(parentId: nil, typeId: type._id, typeLabel: type.label)
                    }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ViewToggleButton()

                if let onOpenAdvancedSearch {
                    AdvancedSearchButton(isFiltering: search.advancedQuery != nil, action: onOpenAdvancedSearch)
                }
            }

            // Boundary before the selected row's entity pills (the
            // invisible toolbar host contributes them) — keeps the
            // table's own controls a separate group.
            if selection != nil {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }
        .createEntitySheet(mode: $pendingCreate, createdId: $pendingCreatedId) {
            if let id = pendingCreatedId {
                selection = id
                Task { await reload() }
            }
            pendingCreatedId = nil
        }
        // Invisible entity-actions host for the selected row — attached to
        // a background so the table's own state (scroll, sort) never
        // re-identifies when the selection appears. It contributes the
        // entity toolbar pills, publishes `entityActions` for the menu
        // bar / shortcuts, hosts the action sheets, and consumes the row
        // context menu's pending action — all rights-gated on the loaded
        // entity, exactly like the list's detail column.
        .background {
            if let entity = detailModel?.entity, entity._id == selection {
                Color.clear
                    .entityToolbarHost(
                        entity: entity,
                        typeLabel: detailModel?.typeLabel,
                        menuId: menuId,
                        onEdited: {
                            Task {
                                // List refetch and entity reload are
                                // independent — run them concurrently.
                                async let list: Void = reload()
                                await detailModel?.load(entityId: entity._id)
                                await list
                            }
                        },
                        onCreated: { newId in
                            selection = newId
                            Task { await reload() }
                        },
                        onDelete: {
                            selection = nil
                            detailModel = nil
                            Task { await reload() }
                        },
                        onListChanged: {
                            Task { await reload() }
                        },
                        onReload: {
                            Task {
                                async let list: Void = reload()
                                await detailModel?.reload(entityId: entity._id)
                                await list
                            }
                        }
                    )
            }
        }
        .task(id: selection) {
            guard let selection else {
                detailModel = nil
                return
            }
            let model = detailModel ?? EntityDetailModel(api: api)
            detailModel = model
            await model.load(entityId: selection)
        }
        .task(id: query) {
            entities = []
            totalCount = 0
            columns = [MainTableColumn(name: "name", type: "string")]
            selection = nil
            detailModel = nil
            #if os(macOS)
            sortOrder = []
            #endif
            sortColumn = nil
            // Await BOTH before building the columns — the single build
            // must already know the labels and ordinal order (reordering
            // live Table columns afterwards traps, see `columns`).
            async let definitions: Void = loadColumnDefinitions()
            await loadEntities()
            await definitions
            rebuildColumns()
        }
        .onChange(of: refreshToken) {
            // Keep existing rows visible while reloading (no empty flash).
            Task { await reload() }
        }
        .onChange(of: search.text) {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                entities = []
                totalCount = 0
                await reload()
            }
        }
    }

    /// The canonical refetch: first page + any newly-surfaced columns.
    private func reload() async {
        await loadEntities()
        rebuildColumns()
    }

    // MARK: - Columns (auto-detected, webapp parity)

    /// The column list the Table renders. STATE, not a computed property,
    /// and mutated append-only — SwiftUI's `TableColumnCollection` traps
    /// (`EXC_BREAKPOINT` in its subscript) when live dynamic columns are
    /// reordered or removed out from under it on iPadOS. The list is built
    /// once per query — entities and definitions awaited together so the
    /// single build already has labels and ordinal order — and later pages
    /// may only append new columns at the end. A query change swaps the
    /// whole Table identity (`.id(query)`) instead of shrinking in place.
    @State var columns = [MainTableColumn(name: "name", type: "string")]

    /// Merge newly-seen properties into `columns`. First build (only the
    /// seed `name` column present) orders by the definitions' `ordinal`
    /// (undefined properties last, alphabetically — mirrors
    /// `table.vue::tableColumnsWithTypes` + type ordering); later calls
    /// append at the end, never reordering what the Table already shows.
    private func rebuildColumns() {
        let seen = Set(columns.map(\.name))
        var freshSet: Set<String> = []
        var freshNames: [String] = []
        var types: [String: String] = [:]

        // ONE pass over the rows: collect unseen property names and detect
        // each one's type from its first non-empty value (webapp's
        // detection order) — no per-key sorting, no per-column re-scan.
        for entity in entities {
            guard let properties = entity.additionalProperties else { continue }

            for (key, values) in properties where !key.hasPrefix("_") && !seen.contains(key) {
                if freshSet.insert(key).inserted {
                    freshNames.append(key)
                }
                if types[key] == nil, let value = values.first {
                    types[key] = Self.detectedType(of: value)
                }
            }
        }

        guard !freshNames.isEmpty else { return }

        var fresh = freshNames.map { MainTableColumn(name: $0, type: types[$0] ?? "string") }
        if columns.count == 1 {
            fresh.sort {
                let a = columnOrdinals[$0.name] ?? .greatestFiniteMagnitude
                let b = columnOrdinals[$1.name] ?? .greatestFiniteMagnitude
                if a != b { return a < b }
                return $0.name < $1.name
            }
        } else {
            // Late-appearing columns append alphabetically — dictionary
            // iteration order above isn't deterministic.
            fresh.sort { $0.name < $1.name }
        }
        columns.append(contentsOf: fresh)
    }

    /// Value shape → column type, in the webapp's detection order.
    private static func detectedType(of value: PropertyValue) -> String {
        if value.number != nil { return "number" }
        if value.boolean != nil { return "boolean" }
        if value.reference != nil { return "reference" }
        if value.date != nil { return "date" }
        if value.datetime != nil { return "datetime" }
        if value.filename != nil { return "filename" }
        if value.filesize != nil { return "filesize" }
        return "string"
    }

    // MARK: - Table body

    /// Platform split, each side on the implementation that actually works
    /// there (both verified on-device, July 2026):
    ///   - macOS: native `Table` — resizable columns, sticky header, sound
    ///     two-axis scrolling. (The hand-rolled layout mis-sized its
    ///     viewport there.)
    ///   - iPadOS: hand-rolled single two-axis ScrollView with a pinned
    ///     header — the native `Table` lays its rows out around a
    ///     ZERO-SIZED collection view on iPadOS 26 (rows paint unclipped,
    ///     nothing scrolls; verified by UIScrollView introspection).
    ///
    /// Rows select (arming the entity actions via the invisible toolbar
    /// host) but never open the entity — the table is an overview; opening
    /// happens via double-click, ⌘-click, or the row context menu's
    /// "Open in New Window" — all into the auxiliary entity window.
    /// Sorting refetches server-side.
    @ViewBuilder
    private var tableBody: some View {
        #if os(macOS)
        macTable
        #else
        padTable
        #endif
    }

    #if os(macOS)
    private var macTable: some View {
        let columns = columns

        return Table(entities, selection: tableSelection, sortOrder: $sortOrder) {
            TableColumn("") { entity in
                EntityAvatar(name: entity.displayName, entityId: entity._id, hasPhoto: entity.hasPhoto, size: 18)
                    // Table cells render in their own hosting hierarchy and
                    // don't inherit custom @Observable environment objects
                    // (or the in-app locale) — re-inject what cells need.
                    .environment(api)
                    .onAppear {
                        if entity.id == entities.last?.id && hasMore && !isLoadingMore {
                            Task { await loadMore() }
                        }
                    }
            }
            .width(24)

            TableColumnForEach(columns) { column in
                TableColumn(
                    columnLabels[column.name] ?? column.name,
                    sortUsing: EntityColumnComparator(column: column.name)
                ) { entity in
                    EntityTableCell(entity: entity, column: column.asTableColumn)
                        .environment(\.locale, locale)
                }
                // No `max` — the user resizes freely; the default layout
                // is kept modest by `TableStretchDisabler` instead of a
                // hard cap (a `max` would bound manual resizing too).
                .width(min: 60, ideal: column.name == "name" ? 200 : 160)
            }
        }
        .alternatingRowBackgrounds(.disabled)
        // AppKit bridge: SwiftUI exposes no control over NSTableView's
        // column auto-stretching, which spreads a sparse table's few
        // columns across the whole window regardless of their ideal
        // widths. See `TableStretchDisabler`.
        .background(TableStretchDisabler())
        // Same context menu as the list rows. Attached to the Table
        // itself — outside the cell hosting hierarchy, so the menu items
        // keep the SwiftUI environment (router, open-in-new-tab action)
        // that cells lose. `select` selects the row — the invisible
        // toolbar host then consumes the pending action once the entity
        // loads, same as the list.
        .contextMenu(forSelectionType: EntitySummary.ID.self) { ids in
            if let id = ids.first {
                EntityRowContextMenuItems(entityId: id) {
                    selection = id
                }
            }
        } primaryAction: { ids in
            // Double-click — the table never opens the entity in place;
            // the entity window is the open gesture (same as ⌘-click).
            if let id = ids.first {
                openEntityInNewWindow?.invoke(id)
            }
        }
        // Fresh Table identity per query — the column set must never
        // shrink or reorder in place (see `columns`).
        .id(query)
        .onChange(of: sortOrder) {
            guard let first = sortOrder.first,
                  let column = columns.first(where: { $0.name == first.column }) else { return }

            applySort(column: column, ascending: first.order == .forward)
        }
    }

    /// Table's sort state — mapped onto `sortColumn`/`sortAscending`,
    /// which `requestParams` turns into the server `sort` param.
    @State private var sortOrder: [EntityColumnComparator] = []

    /// Row selection with ⌘-click interception: plain click selects (arms
    /// the entity actions), ⌘-click opens the entity window keeping the current
    /// selection — same `ModifierState` root pattern as the list's
    /// selection binding in `MainView`.
    private var tableSelection: Binding<String?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue, newValue != selection, ModifierState.isCommandHeld {
                    openEntityInNewWindow?.invoke(newValue)
                    return
                }

                selection = newValue
            }
        )
    }
    #else
    // The iPad rendering lives in `MainEntityTable+PadTable.swift`; only
    // its stored state stays here (extensions can't hold @State).

    /// Per-column widths, adjusted via the header drag handles.
    /// Session-local, like the macOS table's NSTableView widths.
    @State var padColumnWidths: [String: CGFloat] = [:]

    /// Width of the resized column at drag start — deltas apply against
    /// this so the drag doesn't compound.
    @State var padDragBaseWidth: CGFloat?
    #endif

    /// Server-side sort — capture the column's detected type NOW (the
    /// column set derives from loaded entities and can be stale at request
    /// time), then refetch keeping the current rows visible (no flash).
    func applySort(column: MainTableColumn, ascending: Bool) {
        sortColumn = column.name
        sortColumnType = column.type == "reference" ? "string" : column.type
        sortAscending = ascending
        Task { await reload() }
    }

    // MARK: - Data loading

    /// Resolve the query's entity type and fetch its property definitions
    /// for header labels and column order. The query names the type
    /// directly (`_type.reference`) or by name (`_type.string`, needing
    /// one lookup); anything else (free search across types) keeps
    /// raw-name headers in alphabetical order.
    private func loadColumnDefinitions() async {
        columnLabels = [:]
        columnOrdinals = [:]
        let params = query.parseURLQuery()

        var typeId = params["_type.reference"]
        if typeId == nil, let typeName = params["_type.string"] {
            let lookup: [String: String] = [
                "_type.string": "entity",
                "name.string": typeName,
                "props": "_id"
            ]
            let response: EntityListResponse? = try? await api.get("entity", params: lookup)
            typeId = response?.entities.first?._id
        }

        guard let typeId else { return }

        let defParams: [String: String] = [
            "_parent.reference": typeId,
            "props": "name,label,ordinal"
        ]
        guard let response: EntityListResponse = try? await api.get("entity", params: defParams) else { return }

        var labels: [String: String] = [:]
        var ordinals: [String: Double] = [:]
        for definition in response.entities {
            guard let name = PropertyValue.localized(definition.name) else { continue }

            if let label = PropertyValue.localized(definition.additionalProperties?["label"]), !label.isEmpty {
                labels[name] = label
            }
            if let ordinal = definition.additionalProperties?["ordinal"]?.first?.number {
                ordinals[name] = ordinal
            }
        }
        columnLabels = labels
        columnOrdinals = ordinals
    }

    /// Shared query params — no `props`, so the API returns every visible
    /// property (the columns come from the response, webapp parity).
    private func requestParams(skip: Int) -> [String: String] {
        var params = query.parseURLQuery()
        params["limit"] = String(Self.pageSize)
        params["skip"] = String(skip)
        if !search.text.isEmpty { params["q"] = search.text }

        if let sortColumn {
            params["sort"] = "\(sortAscending ? "" : "-")\(sortColumn).\(sortColumnType)"
        }
        return params
    }

    private func loadEntities() async {
        isLoading = true
        if let response: EntityListResponse = try? await api.get("entity", params: requestParams(skip: 0)) {
            entities = response.entities
            totalCount = response.count ?? 0
        }
        isLoading = false
    }

    func loadMore() async {
        isLoadingMore = true
        if let response: EntityListResponse = try? await api.get("entity", params: requestParams(skip: entities.count)) {
            // Dedupe on append — skip/limit pages can overlap when the
            // server-side order shifts between requests, and `Table`
            // TRAPS on duplicate row identifiers (List merely warns).
            let known = Set(entities.map(\.id))
            entities.append(contentsOf: response.entities.filter { !known.contains($0.id) })
            totalCount = response.count ?? totalCount
            // Later pages may surface properties the first page lacked —
            // appended at the end, never reordered.
            rebuildColumns()
        }
        isLoadingMore = false
    }
}

#if os(macOS)
/// Finds the nearest enclosing `NSTableView` and turns off column
/// auto-stretching so columns keep their ideal widths — leftover window
/// width stays empty instead of inflating every column. The user still
/// resizes freely (no `max` constraint); widths inflated by the initial
/// layout pass are clamped back to 200 once, on first contact only, so a
/// manual wider drag is never fought. Minimal AppKit bridge in the
/// `WindowTabTitle` tradition — harness-verified (July 2026, macOS 26).
private struct TableStretchDisabler: NSViewRepresentable {
    final class Coordinator {
        var applied = Set<ObjectIdentifier>()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(from: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView, coordinator: context.coordinator) }
    }

    private func apply(from view: NSView, coordinator: Coordinator) {
        // Climb a few levels, searching each ancestor's subtree — the
        // nearest table is ours (the sidebar's List lives in another
        // split-view branch, well past this range).
        var ancestor: NSView? = view.superview
        for _ in 0..<6 {
            guard let current = ancestor else { return }

            if let table = findTableView(in: current) {
                let id = ObjectIdentifier(table)
                guard !coordinator.applied.contains(id) else { return }

                coordinator.applied.insert(id)
                table.columnAutoresizingStyle = .noColumnAutoresizing
                for column in table.tableColumns where column.width > 200 {
                    column.width = 200
                }
                return
            }
            ancestor = current.superview
        }
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }
}
#endif

// MARK: - Shared toolbar controls

/// The advanced-search filter button — accent-tinted while a filter is
/// applied. One home for the icon, key, and active-tint rule; used by the
/// list (macOS + iPad) and the main table.
struct AdvancedSearchButton: View {
    let isFiltering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("advancedSearch", systemImage: "line.3.horizontal.decrease")
                // macOS borderless toolbar buttons take the label's
                // foreground; iOS ignores it and needs `.tint` instead.
                #if os(macOS)
                .foregroundStyle(isFiltering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                #endif
        }
        #if os(iOS)
        .tint(isFiltering ? Color.accentColor : nil)
        #endif
    }
}

/// List/table toggle for the main results — per-window state on
/// `SessionState` (each tab picks its own view; persisted in the window's
/// session snapshot). Webapp's `show-table` is global; per-tab is the
/// native improvement. The label names the view it switches TO, matching
/// the webapp's toolbar button.
struct ViewToggleButton: View {
    @Environment(SessionState.self) private var session

    var body: some View {
        Button {
            session.showTable.toggle()
        } label: {
            Label(
                session.showTable ? "listView" : "tableView",
                systemImage: session.showTable ? "list.bullet" : "tablecells"
            )
        }
    }
}
