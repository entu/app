// Command palette (⌘K) — centered floating panel over a dimmed backdrop.
//
// Empty state: rights-gated actions for the entity shown in detail
// (published via the `entityActions` / `addChildCommand` focused scene
// values), the active menu's create actions, then the per-database
// recents. Typing replaces the sections with ONE ranked list mixing
// create-actions, entity hits (server `q` search), navigation and app
// commands — matched substrings render bold.
//
// Query grammar: typing a type name offers a type token (Tab accepts);
// with the type set, its property names offer filter/sort tokens.
// A filter drafts as `Property is` (⌥ or clicking the word cycles the
// condition), then value suggestions come from a `group=` facet query
// with counts; Return seals the chip. Sort is a purple token whose arrow
// flips direction. Backspace at the start undoes the last token,
// restoring the text it was accepted from. With tokens present the list
// shows live scoped results and the footer the total count. Token
// queries map to the same API grammar as the advanced search (see
// `PaletteQueryState`).
//
// Design: handoff "Command Palette (15a / 14a)". Container 560pt /
// radius 15; the surface maps to the near-opaque `PaletteBackground`
// colorset and text styles to semantic colors per the native note.

import SwiftUI

/// The ⌘K palette overlay — input row with token chips, ranked result
/// rows, footer.
struct CommandPaletteView: View {
    /// Selected-row fill — the handoff keeps solid `#0071E3` in BOTH
    /// appearances (the dark accent `#409CFF` is chip text only).
    private static let selectionBlue = Color(red: 0x00 / 255, green: 0x71 / 255, blue: 0xE3 / 255)

    // Ranking bands for the typed (token-free) list: search (Return) >
    // grammar (Tab) > actions and navigation > entity hits. Match quality
    // (and a small action-over-navigation nudge) orders within a band;
    // ties keep build order.
    private static let searchBand = 3000
    private static let grammarBand = 2000
    private static let commandBand = 1000

    @Environment(\.colorScheme) private var colorScheme

    // Handoff sizes as Dynamic Type baselines — scale with the user's
    // text-size setting instead of staying fixed.
    @ScaledMetric(relativeTo: .body) private var inputFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var rowFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var iconFontSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var captionFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var headerFontSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 24

    @Environment(CommandPaletteModel.self) private var palette
    @Environment(APIClient.self) private var api
    @Environment(AuthModel.self) private var auth
    @Environment(SearchModel.self) private var search
    @Environment(SessionState.self) private var session
    @Environment(AIChatModel.self) private var chat
    @Environment(MenuModel.self) private var menu

    /// Rights-gated actions of the entity currently shown in detail —
    /// scene-scoped, so they stay published while the palette has focus.
    @FocusedValue(\.entityActions) private var entityActions
    @FocusedValue(\.addChildCommand) private var addChildCommand
    @FocusedValue(\.newEntityCommand) private var newEntityCommand
    @FocusedValue(\.clearCacheCommand) private var clearCacheCommand

    /// Opens an entity in the detail column (`MainView.openPinnedEntity`).
    let onOpenEntity: (String) -> Void

    /// Selects a sidebar menu entry (routes through `MainView`'s
    /// `menuSelection` binding so search/history reset consistently).
    let onSelectMenu: (String) -> Void

    /// Clears navigation back to the dashboard.
    let onGoDashboard: () -> Void

    /// Hands a token query over to the main list
    /// (`MainView.applyAdvancedSearch` — ordered pairs incl. `q`).
    let onApplyQuery: ([(String, String)]) -> Void

    @State private var selectedIndex = 0
    /// Row under the mouse — a faint wash only, independent of the
    /// keyboard selection (like macOS menus).
    @State private var hoveredRowId: String?
    @FocusState private var focused: Bool

    /// Entity rows from the live query, debounced 300 ms.
    @State private var entityHits: [RecentEntity] = []
    /// Total matching count for the footer (`count` of the last fetch).
    @State private var resultCount: Int?
    @State private var searchTask: Task<Void, Never>?

    /// Filter/sort properties of the current type token, mapped from the
    /// shared `EntityDetailModel` type-metadata cache.
    @State private var loadedProperties: (typeId: String, list: [PaletteProperty])?

    /// One value suggestion in the draft-filter stage.
    private struct Facet: Identifiable {
        let label: String
        let raw: String
        let count: Int
        var id: String { raw }
    }

    @State private var facets: [Facet] = []

    #if os(macOS)
    /// ⌥ cycles the draft filter's condition — modifier-only presses
    /// don't reach `onKeyPress`, so watch `flagsChanged` directly.
    @State private var optionMonitor: Any?

    /// Backspace in an *empty* text field doesn't reach `onKeyPress`
    /// either (the field has nothing to delete and swallows the event) —
    /// watch `keyDown` for it to unwind the token row.
    @State private var keyMonitor: Any?
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click/tap outside the panel closes.
            // Dark windows need a stronger dim to read as a scrim.
            Color.black.opacity(colorScheme == .dark ? 0.3 : 0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { palette.close() }

            panel
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 120)
        }
        .onAppear { focused = true }
        .task { await loadTypeOptions() }
        #if os(macOS)
        .onAppear { installOptionMonitor() }
        .onDisappear { removeOptionMonitor() }
        #endif
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            inputRow
            hairline
            resultsList
            // Deviation from the handoff (its empty state has no footer):
            // the key hints are most useful before anything is typed.
            hairline
            footer
        }
        // Liquid Glass panel — the OS 26 native reading of the handoff's
        // "system popover/menu material" note (the mockup rgba surface
        // stays available as the `PaletteBackground` colorset).
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15))
        .shadow(color: .black.opacity(0.25), radius: 22, y: 18)
        // Animate the panel's growth/shrink as rows and tokens come and
        // go, instead of jumping between heights.
        .animation(.snappy(duration: 0.18), value: flatRows.map(\.id))
        .animation(.snappy(duration: 0.18), value: palette.queryState)
        #if os(macOS)
        // Esc fallback for when the text field isn't focused (its own
        // `onKeyPress` handles the focused case).
        .onExitCommand { palette.close() }
        #endif
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color("CardHairline"))
            .frame(height: 0.5)
    }

    // MARK: - Input row

    private var inputRow: some View {
        let state = palette.queryState

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: inputFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            // One stable layout for chips + field — the field keeps its
            // view identity (and focus) across token edits; chips wrap
            // and the field fills whatever remains of the last row.
            PaletteFieldLayout(spacing: 6) {
                if let entityType = state.entityType {
                    PaletteTypeChip(entityType: entityType) {
                        palette.queryState.entityType = nil
                    }
                }
                ForEach(Array(state.filters.enumerated()), id: \.element.id) { index, filter in
                    PaletteFilterChip(
                        filter: filter,
                        onCycleCondition: { cycleCondition(filterAt: index) },
                        onRemove: { removeFilter(at: index) }
                    )
                }
                if let draft = state.draft {
                    PaletteDraftChip(
                        draft: draft,
                        onCycleCondition: { cycleCondition() },
                        onRemove: { palette.queryState.draft = nil }
                    )
                }
                if let sort = state.sort {
                    PaletteSortChip(
                        sort: sort,
                        onFlip: { palette.queryState.sort?.descending.toggle() },
                        onRemove: { palette.queryState.sort = nil }
                    )
                }

                textField
                    .overlay(alignment: .trailing) {
                        if palette.query.isEmpty && state.isEmpty {
                            caption(Text(verbatim: "⌘K"))
                        }
                    }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .onChange(of: palette.queryState) {
            selectedIndex = 0
            scheduleFetch()
        }
    }

    private var textField: some View {
        @Bindable var palette = palette
        return TextField(palette.queryState.isEmpty ? "paletteSearchPlaceholder" : "", text: $palette.query)
            .textFieldStyle(.plain)
            .font(.system(size: inputFontSize))
            .focused($focused)
            .onKeyPress { press in handleKey(press) }
            .onChange(of: palette.query) {
                selectedIndex = 0
                scheduleFetch()
            }
    }

    // MARK: - Keyboard

    /// Esc closes; arrows move the selection; Return runs the selected
    /// row; Tab accepts the selected (or first) grammar suggestion;
    /// Backspace at the start deletes the last token.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            palette.close()
            return .handled
        case .downArrow:
            selectedIndex = min(selectedIndex + 1, flatRows.count - 1)
            return .handled
        case .upArrow:
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        case .return:
            let rows = flatRows
            guard rows.indices.contains(selectedIndex) else { return .ignored }

            invoke(rows[selectedIndex])
            return .handled
        case .tab:
            let rows = flatRows
            if rows.indices.contains(selectedIndex), rows[selectedIndex].isGrammar {
                invoke(rows[selectedIndex])
            } else if let first = rows.first(where: \.isGrammar) {
                invoke(first)
            }
            return .handled
        case .delete:
            guard palette.query.isEmpty, !palette.queryState.isEmpty else { return .ignored }

            removeLastToken()
            return .handled
        default:
            return .ignored
        }
    }

    #if os(macOS)
    private func installOptionMonitor() {
        guard optionMonitor == nil else { return }

        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // Press only (flags contain ⌥) — releases pass through.
            if event.modifierFlags.contains(.option), palette.queryState.draft != nil {
                cycleCondition()
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 51 = backspace. Consume it when it unwinds a token so the
            // system doesn't also beep on the empty field.
            if event.keyCode == 51, palette.query.isEmpty, !palette.queryState.isEmpty {
                removeLastToken()
                return nil
            }
            return event
        }
    }

    private func removeOptionMonitor() {
        if let optionMonitor {
            NSEvent.removeMonitor(optionMonitor)
        }
        optionMonitor = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
    #endif

    // MARK: - Token editing

    private func acceptEntityType(_ entityType: PaletteEntityType) {
        palette.queryState.entityTypeTypedText = palette.query
        palette.queryState.entityType = entityType
        palette.query = ""
        loadProperties(for: entityType)
    }

    private func acceptFilter(_ property: PaletteProperty) {
        palette.queryState.draft = PaletteFilterDraft(property: property, typedText: palette.query)
        palette.query = ""
    }

    private func acceptSort(_ property: PaletteProperty) {
        palette.queryState.sort = PaletteSort(property: property, typedText: palette.query)
        palette.query = ""
    }

    /// Seal the draft filter with a value — the chip closes and the live
    /// results below reflect it. A chip with the same property AND
    /// condition is replaced — request params are keyed by
    /// property+condition, so a duplicate would silently drop one of the
    /// two and the results would no longer match the visible chips.
    private func commitValue(label: String, raw: String) {
        guard let draft = palette.queryState.draft else { return }

        palette.queryState.filters.removeAll {
            $0.property == draft.property && $0.condition == draft.condition
        }
        palette.queryState.filters.append(PaletteFilter(
            property: draft.property,
            condition: draft.condition,
            value: raw,
            valueLabel: label,
            typedText: draft.typedText,
            valueTypedText: palette.query
        ))
        palette.queryState.draft = nil
        palette.query = ""
    }

    /// ⌥ / condition click — cycle the draft's (or a sealed filter's)
    /// condition through the property's set.
    private func cycleCondition(filterAt index: Int? = nil) {
        if let index {
            guard palette.queryState.filters.indices.contains(index) else { return }

            var filter = palette.queryState.filters[index]
            filter.condition = next(after: filter.condition, of: filter.property)
            palette.queryState.filters[index] = filter
        } else if var draft = palette.queryState.draft {
            draft.condition = next(after: draft.condition, of: draft.property)
            palette.queryState.draft = draft
        }
    }

    private func next(after condition: PaletteCondition, of property: PaletteProperty) -> PaletteCondition {
        let conditions = property.conditions
        let index = conditions.firstIndex(of: condition) ?? 0
        return conditions[(index + 1) % conditions.count]
    }

    private func removeFilter(at index: Int) {
        guard palette.queryState.filters.indices.contains(index) else { return }

        palette.queryState.filters.remove(at: index)
    }

    /// Backspace at the start of empty free text — undo the last token
    /// acceptance, restoring the text that was typed before it (so a
    /// mistaken Tab never costs retyping). A sealed filter steps back to
    /// its draft with the value prefix; holding Backspace erases the
    /// restored text and keeps unwinding the whole token row.
    private func removeLastToken() {
        var state = palette.queryState
        if let draft = state.draft {
            state.draft = nil
            palette.query = draft.typedText
        } else if let sort = state.sort {
            state.sort = nil
            palette.query = sort.typedText
        } else if let last = state.filters.popLast() {
            state.draft = PaletteFilterDraft(property: last.property, condition: last.condition, typedText: last.typedText)
            palette.query = last.valueTypedText
        } else if state.entityType != nil {
            palette.query = state.entityTypeTypedText
            state.entityType = nil
            state.entityTypeTypedText = ""
        }
        palette.queryState = state
    }

    // MARK: - Grammar data

    /// Entity types for type-token suggestions — cached on the palette
    /// model across opens (invalidated on database/language change);
    /// fetched through the shared advanced-search loader.
    private func loadTypeOptions() async {
        guard palette.typeOptions.isEmpty else { return }

        palette.typeOptions = await AdvancedSearchModel.fetchEntityTypes(api: api).map { option in
            PaletteEntityType(typeId: option._id, typeName: option.name, label: option.label)
        }
    }

    /// Filter/sort properties of a type — served from the shared
    /// `EntityDetailModel` type-metadata cache (language-keyed, cleared
    /// on database change), so types the detail view already loaded cost
    /// no extra fetch.
    private func loadProperties(for entityType: PaletteEntityType) {
        guard loadedProperties?.typeId != entityType.typeId else { return }

        Task {
            let metadata = await EntityDetailModel.typeMetadata(typeId: entityType.typeId, api: api)
            let properties = metadata.definitions.compactMap { definition -> PaletteProperty? in
                guard !definition.hidden, !definition.name.isEmpty else { return nil }

                return PaletteProperty(
                    name: definition.name,
                    type: definition.type,
                    label: definition.displayLabel()
                )
            }
            loadedProperties = (entityType.typeId, properties)
        }
    }

    /// Properties driving filter/sort suggestions — only the chosen
    /// type's own set: the grammar requires the type token first (its
    /// definitions give each property an unambiguous datatype).
    private var activeProperties: [PaletteProperty] {
        guard let entityType = palette.queryState.entityType,
              let loaded = loadedProperties, loaded.typeId == entityType.typeId else { return [] }
        return loaded.list
    }

    // MARK: - Rows

    /// One selectable palette row — an action (icon + title) or an entity.
    private struct PaletteRow: Identifiable {
        enum Content {
            case action(icon: String, title: String)
            case entity(RecentEntity)
        }

        let id: String
        let content: Content
        /// Right-aligned plain caption — entity type, "Navigate", counts.
        var detail: String?
        /// Right-aligned key hint (⌘E, Tab, …) rendered as a bordered
        /// key cap, so it can't be mistaken for an entity type label.
        var keyHint: String?
        /// Grammar suggestions: accepted by Tab, and running them keeps
        /// the palette open (they build tokens rather than finish a task).
        var isGrammar = false
        /// Entity rows from the live search — grouped under their own
        /// "Matching entities" section header.
        var isEntityHit = false
        let run: () -> Void

        /// Text the ranking matches against and the row displays.
        var searchText: String {
            switch content {
            case .action(_, let title): title
            case .entity(let entity): entity.name
            }
        }
    }

    private struct PaletteSection: Identifiable {
        let id: String
        let title: String
        let rows: [PaletteRow]
    }

    /// In-app-language string for a palette row title (matched against the
    /// typed filter, so it must be a plain `String`, not a `Text` key).
    private func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .currentLocalized)
    }

    private var trimmedQuery: String {
        palette.query.trimmingCharacters(in: .whitespaces)
    }

    /// Grammar rows never close the palette; everything else does.
    private func invoke(_ row: PaletteRow) {
        if !row.isGrammar {
            palette.close()
        }
        row.run()
    }

    // MARK: - Row builders

    /// The detail entity's rights-gated action rows — only rows whose
    /// closure is non-nil, same gating and same order as the toolbar
    /// buttons (`EntityToolbar`): add child, edit, duplicate, parents,
    /// rights, history. Shortcut hints mirror the Entity menu.
    private var entityActionRows: [PaletteRow] {
        guard let actions = entityActions else { return [] }

        var rows: [PaletteRow] = []
        // One row per addable child type — the palette IS a picker, so
        // never route through the extra type-chooser sheet. ⌃⌘N creates
        // directly only when there's a single type — hint it only then.
        let addOptions = addChildCommand?.options ?? []
        for option in addOptions {
            rows.append(PaletteRow(
                id: "addChild-\(option.id)",
                content: .action(icon: "plus", title: loc("addOneChild \(option.label.lowercased())")),
                keyHint: addOptions.count == 1 ? "⌃⌘N" : nil,
                run: option.create
            ))
        }

        let actionTable: [(id: String, icon: String, title: String.LocalizationValue, key: String?, run: (() -> Void)?)] = [
            ("edit", "pencil", "edit", "⌘E", actions.edit),
            ("duplicate", "doc.on.doc", "duplicate", "⌘D", actions.duplicate),
            ("parents", "arrow.up.folder", "parents", nil, actions.parents),
            ("rights", "person.2", "rights", "⌘I", actions.rights),
            ("history", "clock.arrow.circlepath", "history", "⌘Y", actions.history)
        ]
        for entry in actionTable {
            guard let run = entry.run else { continue }

            rows.append(PaletteRow(
                id: entry.id,
                content: .action(icon: entry.icon, title: loc(entry.title)),
                keyHint: entry.key,
                run: run
            ))
        }
        return rows
    }

    /// "New <Type>" rows for the active menu's addable types. ⌘N creates
    /// directly only when there's a single type — hint it only then.
    private var createRows: [PaletteRow] {
        let options = newEntityCommand?.options ?? []
        return options.map { option in
            PaletteRow(
                id: "new-\(option.id)",
                content: .action(icon: "square.and.pencil", title: loc("addOne \(option.label.lowercased())")),
                keyHint: options.count == 1 ? "⌘N" : nil,
                run: option.create
            )
        }
    }

    /// Navigation rows: sidebar menu entries, dashboard, own profile, and
    /// database switching. All carry the "Navigate" caption per the design.
    private var navigationRows: [PaletteRow] {
        let navigate = loc("paletteNavigate")
        var rows: [PaletteRow] = []

        for item in menu.groups.flatMap(\.items) {
            rows.append(PaletteRow(
                id: "menu-\(item._id)",
                content: .action(icon: "chevron.right", title: loc("paletteGoTo \(item.name)")),
                detail: navigate
            ) {
                onSelectMenu(item._id)
            })
        }

        rows.append(PaletteRow(
            id: "dashboard",
            content: .action(icon: "chevron.right", title: loc("paletteGoDashboard")),
            detail: navigate,
            run: onGoDashboard
        ))

        if let userId = auth.currentUserId {
            rows.append(PaletteRow(
                id: "profile",
                content: .action(icon: "chevron.right", title: loc("paletteMyProfile")),
                detail: navigate
            ) {
                onOpenEntity(userId)
            })
        }

        for database in auth.databases where database._id != api.databaseId {
            rows.append(PaletteRow(
                id: "db-\(database._id)",
                content: .action(icon: "chevron.right", title: loc("paletteSwitchDatabase \(database.name)")),
                detail: navigate
            ) {
                auth.selectDatabase(database)
            })
        }
        for publicId in auth.publicDatabases where publicId != api.databaseId {
            rows.append(PaletteRow(
                id: "db-public-\(publicId)",
                content: .action(icon: "chevron.right", title: loc("paletteSwitchDatabase \(publicId)")),
                detail: navigate
            ) {
                auth.selectPublicDatabase(publicId)
            })
        }

        return rows
    }

    /// App-level command rows: advanced search, AI chat, reload, clear
    /// cache, language switch, sign out.
    private var appCommandRows: [PaletteRow] {
        var rows: [PaletteRow] = []

        rows.append(PaletteRow(
            id: "advancedSearch",
            content: .action(icon: "slider.horizontal.3", title: loc("advancedSearch"))
        ) {
            search.showAdvanced = true
        })

        rows.append(PaletteRow(
            id: "aiChat",
            content: .action(icon: "sparkles", title: loc("paletteOpenChat"))
        ) {
            chat.isOpen = true
        })

        if let reload = entityActions?.reload {
            rows.append(PaletteRow(
                id: "reload",
                content: .action(icon: "arrow.clockwise", title: loc("menuReloadEntity")),
                keyHint: "⌘R",
                run: reload
            ))
        }

        if let clearCache = clearCacheCommand {
            rows.append(PaletteRow(
                id: "clearCache",
                content: .action(icon: "arrow.counterclockwise", title: loc("menuClearCache")),
                keyHint: "⇧⌘R",
                run: clearCache.invoke
            ))
        }

        for language in [AppLanguage.english, AppLanguage.estonian]
        where language.rawValue != AppLanguage.resolvedLanguageCode {
            let name = loc(language == .english ? "languageEnglish" : "languageEstonian")
            rows.append(PaletteRow(
                id: "language-\(language.rawValue)",
                content: .action(icon: "globe", title: loc("paletteLanguage \(name)"))
            ) {
                UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey)
            })
        }

        rows.append(PaletteRow(
            id: "signOut",
            content: .action(icon: "rectangle.portrait.and.arrow.right", title: loc("signOut"))
        ) {
            auth.logOut()
        })

        return rows
    }

    /// Global-search fallback row — clears menu/advanced scope and puts
    /// the text into the toolbar search field.
    private func searchEverywhereRow(_ query: String) -> PaletteRow {
        PaletteRow(
            id: "searchEverywhere",
            content: .action(icon: "magnifyingglass", title: loc("paletteSearchEverywhere \(query)"))
        ) {
            session.selectedMenuId = nil
            session.selectedEntityId = nil
            session.entityHistory = []
            search.advancedQuery = nil
            search.text = query
        }
    }

    /// "Search "text" in <menu entry>" — keeps the active menu's scope
    /// and puts the text into the toolbar search field (any applied
    /// advanced query is dropped: it would override the menu scope).
    private func searchInMenuRow(_ query: String, menuItem: MenuEntity) -> PaletteRow {
        PaletteRow(
            id: "searchInMenu",
            content: .action(icon: "magnifyingglass", title: loc("paletteSearchInMenu \(query) \(menuItem.name)"))
        ) {
            session.selectedEntityId = nil
            session.entityHistory = []
            search.advancedQuery = nil
            search.text = query
        }
    }

    /// "Search "text" in <Type>" — applies the token query plus text to
    /// the main list through the advanced-search pipeline.
    private func searchInTypeRow(_ query: String, entityType: PaletteEntityType) -> PaletteRow {
        PaletteRow(
            id: "searchIn",
            content: .action(icon: "magnifyingglass", title: loc("paletteSearchIn \(query) \(entityType.label)"))
        ) {
            onApplyQuery(palette.queryState.queryPairs() + [("q", query)])
        }
    }

    private func entityRow(_ entity: RecentEntity, idPrefix: String, isHit: Bool = false) -> PaletteRow {
        PaletteRow(id: "\(idPrefix)-\(entity._id)", content: .entity(entity), detail: entity.typeLabel, isEntityHit: isHit) {
            onOpenEntity(entity._id)
        }
    }

    // MARK: - Grammar rows

    /// Items matching the folded query, best quality first; ties keep
    /// source order.
    private func rankedMatches<Item>(
        _ items: [Item],
        foldedQuery: String,
        keys: (Item) -> (String, String)
    ) -> [Item] {
        items.enumerated()
            .compactMap { offset, item -> (Item, Int, Int)? in
                let (primary, secondary) = keys(item)
                let quality = max(matchQuality(primary, foldedQuery), matchQuality(secondary, foldedQuery))
                return quality > 0 ? (item, quality, offset) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    /// `<Type> — filter type…` suggestions for the typed text.
    private func typeSuggestionRows(_ foldedQuery: String) -> [PaletteRow] {
        rankedMatches(palette.typeOptions, foldedQuery: foldedQuery, keys: { ($0.foldedLabel, $0.foldedName) })
            .prefix(3)
            .map { option in
                PaletteRow(
                    id: "type-\(option.typeId)",
                    content: .action(icon: "line.3.horizontal.decrease", title: loc("paletteFilterType \(option.label)")),
                    keyHint: "⇥",
                    isGrammar: true
                ) {
                    acceptEntityType(option)
                }
            }
    }

    /// `Filter by <Property>…` / `Sort by <Property>…` suggestions.
    private func propertySuggestionRows(_ foldedQuery: String) -> [PaletteRow] {
        let matches = rankedMatches(activeProperties, foldedQuery: foldedQuery, keys: { ($0.foldedLabel, $0.foldedName) })

        var rows: [PaletteRow] = matches.prefix(3).map { property in
            PaletteRow(
                id: "filterBy-\(property.name)",
                content: .action(icon: "line.3.horizontal.decrease", title: loc("paletteFilterBy \(property.label)")),
                keyHint: "⇥",
                isGrammar: true
            ) {
                acceptFilter(property)
            }
        }

        rows += matches.prefix(2).map { property in
            PaletteRow(
                id: "sortBy-\(property.name)",
                content: .action(icon: "arrow.up.arrow.down", title: loc("paletteSortBy \(property.label)")),
                keyHint: "⇥",
                isGrammar: true
            ) {
                acceptSort(property)
            }
        }

        return rows
    }

    /// Value suggestions for the draft filter — live DB values with counts.
    private var valueRows: [PaletteRow] {
        var rows: [PaletteRow] = facets.map { facet in
            PaletteRow(
                id: "value-\(facet.raw)",
                content: .entity(RecentEntity(_id: facet.raw, name: facet.label)),
                detail: loc("entityCount \(facet.count)"),
                isGrammar: true
            ) {
                commitValue(label: facet.label, raw: facet.raw)
            }
        }

        let query = trimmedQuery
        if !query.isEmpty {
            rows.append(PaletteRow(
                id: "useValue",
                content: .action(icon: "return", title: loc("paletteUseValue \(query)")),
                isGrammar: true
            ) {
                commitValue(label: query, raw: query)
            })
        }
        return rows
    }

    // MARK: - Sections

    /// Empty-state sections: the detail entity's actions, the active
    /// menu's create actions, then recents.
    private var emptySections: [PaletteSection] {
        var sections: [PaletteSection] = []

        if let name = entityActions?.entityName {
            let rows = entityActionRows
            if !rows.isEmpty {
                let title = [entityActions?.entityTypeLabel, name]
                    .compactMap(\.self)
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                sections.append(PaletteSection(id: "entity", title: title, rows: rows))
            }
        }

        // Menu-level "New <Type>" rows — the toolbar's Add button
        // equivalents, titled with the active menu entry's name.
        let creates = createRows
        if !creates.isEmpty {
            let menuName = menu.groups.flatMap(\.items)
                .first { $0._id == session.selectedMenuId }?.name
            sections.append(PaletteSection(id: "create", title: menuName ?? loc("add"), rows: creates))
        }

        // Recents — the current detail entity is already the section above.
        let currentId = entityActions?.entityId
        let recentRows = palette.recents
            .filter { $0._id != currentId }
            .map { entityRow($0, idPrefix: "recent") }
        if !recentRows.isEmpty {
            sections.append(PaletteSection(id: "recent", title: loc("paletteRecent"), rows: recentRows))
        }

        return sections
    }

    /// 3 = prefix, 2 = word-prefix, 1 = substring, 0 = no match. Both
    /// arguments pre-folded with `paletteFold`.
    private func matchQuality(_ foldedText: String, _ foldedQuery: String) -> Int {
        if foldedText.hasPrefix(foldedQuery) { return 3 }

        let words = foldedText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(foldedQuery) }) { return 2 }
        if foldedText.contains(foldedQuery) { return 1 }
        return 0
    }

    /// Rows for the non-empty state.
    ///
    /// Draft filter → value suggestions. Tokens present → search-in row
    /// (Return default), grammar suggestions (Tab), then live results.
    /// No tokens → the banded ranked mix (see the band constants).
    private var typedRows: [PaletteRow] {
        let query = trimmedQuery
        let foldedQuery = paletteFold(query)
        let state = palette.queryState

        if state.draft != nil {
            return valueRows
        }

        if !state.isEmpty {
            var rows: [PaletteRow] = []
            if !query.isEmpty {
                if let entityType = state.entityType {
                    rows.append(searchInTypeRow(query, entityType: entityType))
                } else {
                    // The type chip was removed but other tokens remain —
                    // re-offer the type token.
                    rows += typeSuggestionRows(foldedQuery)
                }
                rows += propertySuggestionRows(foldedQuery)
            }
            rows += entityHits.map { entityRow($0, idPrefix: "hit", isHit: true) }
            return rows
        }

        guard !query.isEmpty else { return [] }

        var scored: [(row: PaletteRow, score: Int)] = []

        // With a menu active, searching within it is the likelier intent —
        // it outranks (and precedes) the global search.
        if let menuId = session.selectedMenuId,
           let menuItem = menu.groups.flatMap(\.items).first(where: { $0._id == menuId }) {
            scored.append((searchInMenuRow(query, menuItem: menuItem), Self.searchBand + 1))
        }
        scored.append((searchEverywhereRow(query), Self.searchBand))
        for row in typeSuggestionRows(foldedQuery) {
            scored.append((row, Self.grammarBand))
        }
        for row in entityActionRows + createRows + appCommandRows {
            let quality = matchQuality(paletteFold(row.searchText), foldedQuery)
            if quality > 0 { scored.append((row, Self.commandBand + quality * 10 + 3)) }
        }
        for row in navigationRows {
            let quality = matchQuality(paletteFold(row.searchText), foldedQuery)
            if quality > 0 { scored.append((row, Self.commandBand + quality * 10 + 1)) }
        }
        for hit in entityHits {
            // The server matched it even when client-side folding doesn't
            // (multi-word `q`, matches in non-name properties) — floor at 1.
            let quality = max(matchQuality(paletteFold(hit.name), foldedQuery), 1)
            scored.append((entityRow(hit, idPrefix: "hit", isHit: true), quality))
        }

        // Stable: score descending, ties keep build order.
        return scored.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.row)
    }

    /// The one place deciding what the list shows — empty-state sections,
    /// or the ranked list with entity hits under their own header.
    private var sections: [PaletteSection] {
        if palette.query.isEmpty && palette.queryState.isEmpty {
            return emptySections
        }

        let rows = typedRows
        let hitRows = rows.filter(\.isEntityHit)
        var result = [PaletteSection(id: "ranked", title: "", rows: rows.filter { !$0.isEntityHit })]
        if !hitRows.isEmpty {
            result.append(PaletteSection(id: "hits", title: loc("paletteEntities"), rows: hitRows))
        }
        return result
    }

    /// Rows in display order for the ↑↓ selection index.
    private var flatRows: [PaletteRow] {
        sections.flatMap(\.rows)
    }

    // MARK: - Fetching (live results / value facets)

    private func scheduleFetch() {
        searchTask?.cancel()
        let query = trimmedQuery
        let state = palette.queryState

        if state.isEmpty && query.isEmpty {
            entityHits = []
            facets = []
            resultCount = nil
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            if state.draft != nil {
                await fetchFacets(state: state, prefix: query)
            } else {
                await fetchResults(state: state, text: query)
            }
        }
    }

    /// Live results for the current tokens and/or free-text `q` — with no
    /// tokens this is the plain global search.
    private func fetchResults(state: PaletteQueryState, text: String) async {
        var params = state.queryParams()
        if !text.isEmpty {
            params["q"] = text
        }
        params["props"] = "_type.string,name,photo"
        params["limit"] = "10"

        guard let response: EntityListResponse = try? await api.get("entity", params: params),
              state == palette.queryState, text == trimmedQuery else { return }

        entityHits = response.entities.map { entity in
            RecentEntity(
                _id: entity._id,
                name: entity.displayName,
                typeLabel: PropertyValue.localized(entity.additionalProperties?["_type"]),
                hasPhoto: entity.hasPhoto
            )
        }
        resultCount = response.count
    }

    /// Distinct values of the draft property with counts, via the list
    /// endpoint's `group=` facet — prefix-filtered server-side for
    /// string-like properties, client-side otherwise. The whole token
    /// query (type + every sealed filter) scopes the facet, so counts
    /// reflect the query built so far and an empty suggestion list
    /// reveals a dead-end before the value is even picked. Note: the
    /// API's group branch ignores `limit` — the response carries every
    /// distinct value; the client keeps the top 8 by count.
    private func fetchFacets(state: PaletteQueryState, prefix: String) async {
        guard let draft = state.draft else { return }

        let property = draft.property
        var params = state.queryParams()
        params.removeValue(forKey: "sort")
        params["group"] = "\(property.name).\(property.searchField)"
        params["props"] = property.name
        let stringLike = ["string", "text", "filename"].contains(property.searchField)
        if !prefix.isEmpty && stringLike {
            params["\(property.name).\(property.searchField).regex"] = "/\(PaletteQueryState.regexEscape(prefix))/i"
        }

        guard let response: EntityListResponse = try? await api.get("entity", params: params),
              state == palette.queryState, prefix == trimmedQuery else { return }

        let foldedPrefix = paletteFold(prefix)
        var seen = Set<String>()
        var collected: [Facet] = []
        for entity in response.entities {
            let values = property.name == "name" ? entity.name : entity.additionalProperties?[property.name]
            guard let (label, raw) = facetValue(values, property: property), seen.insert(raw).inserted else { continue }

            // Non-string facets can't prefix-filter server-side.
            if !prefix.isEmpty && !stringLike && !paletteFold(label).hasPrefix(foldedPrefix) { continue }

            collected.append(Facet(label: label, raw: raw, count: entity._count ?? 0))
        }
        facets = Array(collected.sorted { $0.count > $1.count }.prefix(8))
    }

    /// Display label + raw API value for one grouped facet row.
    private func facetValue(_ values: [PropertyValue]?, property: PaletteProperty) -> (String, String)? {
        guard let value = PropertyValue.best(values) else { return nil }

        switch property.type {
        case "number", "counter":
            guard let number = value.number else { return nil }

            let label = number == number.rounded() ? String(Int(number)) : String(number)
            return (label, label)
        case "boolean":
            guard let boolean = value.boolean else { return nil }
            return (String(boolean), String(boolean))
        case "date":
            guard let date = value.date else { return nil }
            return (String(date.prefix(10)), String(date.prefix(10)))
        case "datetime":
            guard let datetime = value.datetime else { return nil }
            return (String(datetime.prefix(10)), datetime)
        default:
            guard let string = value.string, !string.isEmpty else { return nil }
            return (string, string)
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        let isEmptyState = palette.query.isEmpty && palette.queryState.isEmpty
        let sections = sections
        var index = -1
        // Assign flat selection indices in render order.
        let indexed = sections.map { section in
            (section, section.rows.map { row in
                index += 1
                return (row, index)
            })
        }
        let isEmpty = indexed.allSatisfy { $0.1.isEmpty }

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(indexed, id: \.0.id) { section, rows in
                        if !section.title.isEmpty {
                            sectionHeader(section.title)
                        }
                        // No hover-selection — the highlight is keyboard
                        // state (↑↓); hovering only paints a faint wash.
                        ForEach(rows, id: \.0.id) { row, rowIndex in
                            rowView(row, isSelected: rowIndex == selectedIndex, isHovered: row.id == hoveredRowId)
                                .id(row.id)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredRowId = row.id
                                    } else if hoveredRowId == row.id {
                                        hoveredRowId = nil
                                    }
                                }
                        }
                    }

                    if isEmpty {
                        Text(isEmptyState ? "paletteNoRecents" : "noResults")
                            .font(.system(size: rowFontSize))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) {
                let rows = flatRows
                guard rows.indices.contains(selectedIndex) else { return }

                proxy.scrollTo(rows[selectedIndex].id)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(verbatim: title)
            .textCase(.uppercase)
            .font(.system(size: headerFontSize, weight: .semibold))
            .kerning(0.8)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func rowView(_ row: PaletteRow, isSelected: Bool, isHovered: Bool) -> some View {
        Button {
            invoke(row)
        } label: {
            HStack(spacing: 9) {
                switch row.content {
                case .action(let icon, _):
                    // Design: thin gray stroke icons; white at 80% when selected.
                    Image(systemName: icon)
                        .font(.system(size: iconFontSize, weight: .light))
                        .frame(width: 16)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                case .entity(let entity):
                    EntityAvatar(name: entity.name, entityId: entity._id, hasPhoto: entity.hasPhoto, size: avatarSize)
                }

                Text(row.searchText.emphasizing(trimmedQuery))
                    .font(.system(size: rowFontSize))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer(minLength: 8)

                if let detail = row.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: captionFontSize))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }
                if let keyHint = row.keyHint {
                    keyCap(keyHint, selected: isSelected)
                }
                // Selected row always ends with a Return cap so it's
                // clear Enter activates it.
                if isSelected {
                    keyCap("↩", selected: true)
                }
            }
            // Uniform row height — action rows match the 24pt avatar of
            // entity rows.
            .frame(minHeight: avatarSize)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isSelected ? Self.selectionBlue : (isHovered ? Color.primary.opacity(0.06) : .clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A bordered key-cap badge (⌘E, Tab, Return) — visually distinct
    /// from plain captions like entity type labels.
    private func keyCap(_ text: String, selected: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: headerFontSize, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? AnyShapeStyle(.white.opacity(0.4)) : AnyShapeStyle(.secondary.opacity(0.4)), lineWidth: 0.5)
            }
    }

    /// Tertiary caption text — the footer/hint text style.
    private func caption(_ text: Text) -> some View {
        text
            .font(.system(size: captionFontSize))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Footer

    private var footer: some View {
        let state = palette.queryState

        return HStack(spacing: 4) {
            if state.draft != nil {
                keyCap("⌥")
                caption(Text("paletteOptionHint"))
            } else if !state.isEmpty {
                caption(Text(verbatim: resultSummary))
            } else {
                caption(Text("paletteFooterHint"))
            }

            Spacer(minLength: 16)

            if !state.isEmpty && state.draft == nil {
                keyCap("⌫")
                caption(Text("paletteBackspaceHint"))
            } else {
                keyCap("↑")
                keyCap("↓")
                keyCap("↩")
                keyCap("esc")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// `6 entities · sorted by Subtitle ↓` — the live-results footer.
    private var resultSummary: String {
        var summary = loc("entityCount \(resultCount ?? entityHits.count)")
        if let sort = palette.queryState.sort {
            summary += " · " + loc("paletteSortedBy \(sort.property.label)") + (sort.descending ? " ↓" : " ↑")
        }
        return summary
    }
}
