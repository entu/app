// Create/edit sheet for a single entity using the webapp's autosave-on-blur
// model — no Save button. Each editor commits the moment the user finishes
// touching it; the commit branches on `currentEntityId` and the value's
// existing `_id`:
//
//   currentEntityId | value._id | present? | call
//   ----------------------------------------------------------------
//   nil             | nil       | yes      | POST /entity              (create)
//   id              | nil       | yes      | POST /entity/{id}         (add value)
//   id              | _id       | yes      | POST /entity/{id}         (edit value)
//   id              | _id       | no/empty | DELETE /property/{_id}    (remove value)
//
// Mirrors `components/property/edit.vue::updateValue`. In create mode the
// first commit promotes the sheet into edit mode by storing the response id.
// Whole-entity delete sits in `.destructiveAction` (mirrors `UserSheet`).

import SwiftUI

/// Edit vs create entry points for `EntityEditView`. `Hashable +
/// Identifiable` so it can drive `.sheet(item:)`. `typeLabel` lets the
/// sheet build the navigation title without re-fetching the type entity.
enum EntityEditMode: Hashable, Identifiable {
    case edit(entityId: String)
    case create(parentId: String?, typeId: String, typeLabel: String)

    var id: String {
        switch self {
        case .edit(let id): return "edit:\(id)"
        case .create(let parent, let type, _): return "create:\(parent ?? ""):\(type)"
        }
    }
}

/// Modal sheet that creates or edits a single entity, autosaving per-field.
struct EntityEditView: View {
    // Internal (non-private) so extensions in companion files
    // (`EntityEditViewLoading.swift`, `EntityEditViewCommit.swift`) can read state.
    @Environment(AuthModel.self) var auth
    @Environment(APIClient.self) var api
    @Environment(DeepLinkRouter.self) var router
    @Environment(\.dismiss) var dismiss

    let mode: EntityEditMode

    /// Called with the entity's id once the first field has been committed
    /// (create mode) or the entity exists already (edit mode). Caller can
    /// use it to navigate to the new entity after the sheet closes.
    var onSaved: ((String) -> Void)?

    /// Called after a successful entity delete. Only fires from edit mode.
    /// Caller pops navigation and removes the entity from any list.
    var onDeleted: (() -> Void)?

    @State var entity: EntityDetail?
    @State var definitions: [PropertyDefinition] = []
    @State var values: [String: [EditableValue]] = [:]

    /// UI plugins attached to the type for the current slot (`entity-edit`
    /// when editing, `entity-add` when creating). Empty = no plugin tabs.
    @State var plugins: [Plugin] = []

    /// Selected tab: 0 = the native property form ("Manual input"),
    /// 1…N = `plugins[selectedTab - 1]`.
    @State private var selectedTab = 0

    /// Set up-front in edit mode; in create mode populated by the first
    /// commit's upsert response, after which we're effectively in edit mode.
    @State var currentEntityId: String?

    /// Set up-front from the loaded entity (edit) or the mode payload (create).
    @State var currentTypeId: String?

    /// Type entity's `description` property, localized to the active language.
    /// Rendered as markdown above the form (mirrors webapp's
    /// `entity.type.description` block in `entity/drawer/edit.vue`).
    @State var typeDescription: String?

    @State var isLoading = true
    @State var isDeleting = false
    @State var loadError: String?
    @State var commitError: String?
    @State private var showingDeleteConfirm = false

    /// Serializes commits — two near-simultaneous blurs can't both fire
    /// `createEntity` or race on `currentEntityId` updates.
    @State var commitChain: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SheetHeader(title: headerTitle, subtitle: headerSubtitle)
            #endif
            Group {
                if isLoading {
                    FormPlaceholder()
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    contentBody
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheetNavigationTitle(headerTitle, subtitle: headerSubtitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(isDisabled: isDeleting) { dismiss() }
            }
            if showsDelete {
                ToolbarItem(placement: .destructiveAction) {
                    Button("delete", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .alert(
            Text(deleteConfirmTitle),
            isPresented: $showingDeleteConfirm
        ) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) {
                Task { await deleteEntity() }
            }
        } message: {
            Text("deleteEntityMessage")
        }
        .alert(
            "save",
            isPresented: Binding(
                get: { commitError != nil },
                set: { if !$0 { commitError = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            if let commitError { Text(commitError) }
        }
        .task { await load() }
        .appLanguageScoped()
    }

    /// Sheet title split into action + subtitle so the entity name / type
    /// renders one line below in a secondary style. Mirrors
    /// `components/entity/drawer/edit.vue` (`titleAdd` / `titleChild` /
    /// `titleEdit`).
    private var headerTitle: String {
        switch mode {
        case .edit:
            return String(localized: "edit", bundle: .currentLocalized)
        case .create(let parentId, _, _):
            return parentId == nil
                ? String(localized: "titleAddBare", bundle: .currentLocalized)
                : String(localized: "titleChildBare", bundle: .currentLocalized)
        }
    }

    /// Subtitle: entity name when editing an existing entity, otherwise the
    /// type label. nil only when neither is available (very early in load).
    private var headerSubtitle: String? {
        switch mode {
        case .edit:
            if let name = entity.map(\.displayName), !name.isEmpty {
                return name
            }
            return entity?.typeName
        case .create(_, _, let typeLabel):
            return typeLabel
        }
    }

    // MARK: - macOS header

    /// True when editing an existing entity (drives the plugin slot choice).
    var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    // MARK: - Plugin tabs

    /// The form on its own when the type has no UI plugins, otherwise a
    /// segmented switcher with the form as the first tab ("Manual input") and
    /// one tab per plugin. Mirrors the webapp's `n-tabs` in
    /// `components/entity/drawer/edit.vue` — the tab bar is hidden when there
    /// are no plugins.
    @ViewBuilder
    private var contentBody: some View {
        if plugins.isEmpty {
            formBody
        } else {
            VStack(spacing: 0) {
                Picker("plugins", selection: $selectedTab) {
                    Text("pluginManualInput").tag(0)
                    ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
                        Text(verbatim: plugin.name).tag(index + 1)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                if selectedTab == 0 {
                    formBody
                } else if selectedTab - 1 < plugins.count, let url = pluginURL(plugins[selectedTab - 1]) {
                    // `WebView` has no intrinsic size — fill the tab so the
                    // sheet keeps the height the min frame below establishes,
                    // instead of collapsing to the picker.
                    PluginWebView(url: url, onEntuLink: openEntuLink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Plugin tabs (unlike the grouped Form) don't propose a height, so
            // pin the app's usual sheet minimum — the menu-level Add sheet
            // doesn't set one itself. Width only on macOS so compact iPhone
            // sheets aren't forced wider than the screen.
            .frame(minHeight: 600, maxHeight: .infinity)
            #if os(macOS)
            .frame(minWidth: 640)
            #endif
        }
    }

    /// Build the plugin page URL with the same query params the webapp appends
    /// (`components/entity/drawer/edit.vue`): account (= database), entity or
    /// parent, type, locale, and the user's token. The plugin page calls the
    /// Entu API back with that token.
    ///
    /// The `token` is the full user JWT (webapp parity). It therefore rides in
    /// the page URL — exposed to the plugin origin and its `Referer` headers.
    /// A scoped, short-lived plugin token is the planned hardening (FEATURES
    /// #51); until then this matches the webapp's exposure and no worse.
    private func pluginURL(_ plugin: Plugin) -> URL? {
        guard var components = URLComponents(string: plugin.url), components.scheme == "https" else { return nil }
        var items = components.queryItems ?? []

        if let databaseId = api.databaseId {
            items.append(URLQueryItem(name: "account", value: databaseId))
        }

        switch mode {
        case .edit(let entityId):
            items.append(URLQueryItem(name: "entity", value: entityId))
        case .create(let parentId, _, _):
            if let parentId {
                items.append(URLQueryItem(name: "parent", value: parentId))
            }
        }

        if let typeId = currentTypeId {
            items.append(URLQueryItem(name: "type", value: typeId))
        }

        items.append(URLQueryItem(name: "locale", value: AppLanguage.resolvedLanguageCode))

        if let token = api.token {
            items.append(URLQueryItem(name: "token", value: token))
        }

        components.queryItems = items
        return components.url
    }

    /// A plugin can finish by redirecting to an Entu entity link (e.g. after
    /// an import). Route it through the shared deep-link path — `MainView`
    /// observes the router and navigates — then close the sheet. Returns
    /// `true` when the URL was an Entu link (so the web navigation is
    /// cancelled); `false` lets the plugin navigate normally.
    private func openEntuLink(_ url: URL) -> Bool {
        guard router.handle(url: url) else { return false }

        dismiss()
        return true
    }

    // MARK: - Form body

    /// Type description renders as plain markdown above the form (mirrors
    /// webapp's `text-gray-500` paragraph). Form rows below use the system
    /// grouped style for rounded sections per group.
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let typeDescription, !typeDescription.isEmpty {
                Text(markdown: typeDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            Form {
                ForEach(orderedGroups, id: \.id) { group in
                    Section {
                        ForEach(group.definitions, id: \._id) { def in
                            propertyRows(for: def)
                        }
                    } header: {
                        if let name = group.name {
                            Text(verbatim: name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Visible only in edit mode + owner rights.
    private var showsDelete: Bool {
        guard currentEntityId != nil, let entity else { return false }
        return entity.rights(for: auth.currentUserId).owner
    }

    /// Matches webapp's "Delete entity" / "Kustuta objekt".
    private var deleteConfirmTitle: String {
        String(localized: "deleteEntityConfirmTitle", bundle: .currentLocalized)
    }

    /// Render every editable row for a single property definition. List
    /// properties keep two trailing empty rows automatically (managed by
    /// `manageEmptyFields`), so there's no explicit "Add value" button.
    @ViewBuilder
    private func propertyRows(for def: PropertyDefinition) -> some View {
        let rows = values[def.name] ?? []
        let isFirstFocusable = def._id == firstFocusableDefinitionId

        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            PropertyEditor(
                definition: def,
                value: row,
                showsLabel: !(def.list || def.multilingual) || index == 0,
                valueCount: rows.filter { $0._id != nil }.count,
                onCommit: { await commit(propertyName: def.name, value: row) },
                onFilesPicked: { picks in handleFilesPicked(propertyName: def.name, hostRow: row, picks: picks) },
                onDelete: {
                    if let _id = row._id {
                        await deleteValue(propertyName: def.name, value: row, propertyId: _id)
                    }
                },
                autoFocusOnAppear: isFirstFocusable && index == 0
            )
            .swipeActions {
                // Files use the inline trash button on `savedFileRow`; only
                // list-type non-file rows still need the swipe affordance.
                if def.list, def.type != "file", let _id = row._id {
                    Button(role: .destructive) {
                        Task { await deleteValue(propertyName: def.name, value: row, propertyId: _id) }
                    } label: {
                        Label("removeValue", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Property grouping

    private struct EditorGroup: Identifiable {
        let name: String?
        let definitions: [PropertyDefinition]
        var id: String { name ?? "_ungrouped" }
    }

    /// Group + sort definitions for display. Includes `name` so the user
    /// can edit it (the read view skips name since the title shows it).
    private var orderedGroups: [EditorGroup] {
        let visible = definitions.filter { !$0.hidden && $0.formula == nil && !$0.readonly }
        var byGroup: [String: [PropertyDefinition]] = [:]
        for def in visible {
            byGroup[def.group ?? "", default: []].append(def)
        }
        return byGroup
            .map { EditorGroup(name: $0.key.isEmpty ? nil : $0.key, definitions: $0.value.sorted { $0.ordinal < $1.ordinal }) }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    /// `_id` of the first text-input definition in the form. Used to
    /// auto-focus the first input when the sheet appears (mirrors webapp's
    /// `inputRef.focus()` on drawer open). Returns nil when no definition
    /// has a focusable input — boolean-only forms etc. just don't focus.
    private var firstFocusableDefinitionId: String? {
        for group in orderedGroups {
            for def in group.definitions {
                switch def.type {
                case "text", "number":
                    return def._id
                case "string" where def.set.isEmpty:
                    return def._id
                default:
                    continue
                }
            }
        }
        return nil
    }

    // Per-value commit, file upload, delete and `manageEmptyFields`
    // housekeeping live in `EntityEditViewCommit.swift`.
}
