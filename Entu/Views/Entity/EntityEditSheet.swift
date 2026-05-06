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
    // (`EntityEditSheetLoading.swift`, `EntityEditSheetCommit.swift`) can read state.
    @Environment(AuthModel.self) var auth
    @Environment(APIClient.self) var api
    @Environment(\.dismiss) var dismiss

    let mode: EntityEditMode

    /// Called with the entity's id once the first field has been committed
    /// (create mode) or the entity exists already (edit mode). Caller can
    /// use it to navigate to the new entity after the sheet closes.
    var onSaved: ((String) -> Void)?

    /// Called after a successful entity delete. Only fires from edit mode.
    /// Caller pops navigation and removes the entity from any list.
    var onDeleted: (() -> Void)?

    /// Re-apply the in-app language inside the sheet so confirmation
    /// dialogs / button labels translate. See `AppLanguage` notes.
    @AppStorage(AppLanguage.storageKey) var appLanguage: String = ""

    @State var entity: EntityDetail?
    @State var definitions: [PropertyDefinition] = []
    @State var values: [String: [EditableValue]] = [:]

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
        Group {
            if isLoading {
                // Reserve height so the auto-sizing form sheet (iPad/macOS)
                // doesn't jump from spinner-sized to form-sized on load.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 400)
            } else if let loadError {
                ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 400)
            } else {
                formBody
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .disabled(isDeleting)
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
        .id(appLanguage)
        .environment(\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))
    }

    /// Sheet title — mirrors `components/entity/drawer/edit.vue`:
    /// `titleChild` (with parent), `titleAdd` (create), `titleEdit` (edit).
    private var navigationTitle: Text {
        switch mode {
        case .edit:
            guard let typeName = entity?.typeName, !typeName.isEmpty else {
                return Text("edit")
            }
            return Text("titleEdit \(typeName.lowercased())")
        case .create(let parentId, _, let typeLabel):
            let label = typeLabel.lowercased()
            if parentId != nil {
                return Text("titleChild \(label)")
            }
            return Text("titleAdd \(label)")
        }
    }

    // MARK: - Form body

    /// Type description renders as plain markdown above the form (mirrors
    /// webapp's `text-gray-500` paragraph). Form rows below use the system
    /// grouped style for rounded sections per group.
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let typeDescription, !typeDescription.isEmpty {
                Group {
                    if let attributed = try? AttributedString(markdown: typeDescription) {
                        Text(attributed)
                    } else {
                        Text(verbatim: typeDescription)
                    }
                }
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
                }
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

    // Per-value commit, file upload, delete and `manageEmptyFields`
    // housekeeping live in `EntityEditSheetCommit.swift`.
}
