// Per-entity parents drawer. Mirrors webapp's
// `components/entity/drawer/parents.vue` — lists this entity's `_parent`
// references and lets the user add or remove them.
//
// Removal is per-parent: only parents the active user has `_expander`
// rights on can be removed (the API enforces this; UI hides the delete
// button when the user lacks the right). Add uses a reference picker
// scoped to entities the user can expand.
//
// Editor+ sheet — visibility is gated by the parent EntityToolbar.

import SwiftUI

/// Parents (`_parent`) editor for a single entity.
struct ParentsSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(MenuModel.self) private var menu

    let entityId: String
    var onChanged: (() -> Void)?

    @State private var entity: EntityDetail?
    /// IDs of parent entities the active user can remove (i.e. holds
    /// `_expander` on). Webapp loads these one-by-one; we parallelise
    /// via a `TaskGroup` after the entity payload arrives.
    @State private var canRemoveParents: Set<String> = []
    @State private var isLoading = true
    @State private var isUpdating = false
    @State private var loadError: String?
    @State private var showingPicker = false

    private var parents: [PropertyValue] {
        (entity?.properties["_parent"] ?? [])
            .sorted { ($0.string ?? "").localizedCompare($1.string ?? "") == .orderedAscending }
    }

    private var entityName: String? {
        PropertyValue.localized(entity?.properties["name"])
    }

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
                } else {
                    formBody
                }
            }
        }
        .sheetNavigationTitle(headerTitle, subtitle: headerSubtitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(isDisabled: isUpdating) { dismiss() }
            }
        }
        .task { await load() }
        .appLanguageScoped()
    }

    private var headerTitle: String {
        String(localized: "parents", bundle: .currentLocalized)
    }

    /// Subtitle: the entity's name, nil when it has none.
    private var headerSubtitle: String? {
        (entityName?.isEmpty == false) ? entityName : nil
    }

    // MARK: - Form

    private var formBody: some View {
        Form {
            Section {
                if parents.isEmpty {
                    Text("noParents")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(parents, id: \.self.uniqueId) { parent in
                        parentRow(parent)
                    }
                }
            }
            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("selectNewParent", systemImage: "plus")
                }
                .disabled(isUpdating)
                .sheet(isPresented: $showingPicker) {
                    NavigationStack {
                        ReferencePickerView(
                            query: parentQuery,
                            subtitle: String(localized: "parents", bundle: .currentLocalized)
                        ) { id, _ in
                            showingPicker = false
                            Task { await addParent(reference: id) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func parentRow(_ parent: PropertyValue) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: parent.string ?? parent.reference ?? "")
                .lineLimit(1)
            Spacer(minLength: 8)
            if let propertyId = parent._id,
               let parentId = parent.reference,
               canRemoveParents.contains(parentId) {
                Button(role: .destructive) {
                    Task { await deleteParent(propertyId: propertyId) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
            }
        }
    }

    // MARK: - Picker query

    /// Reference picker query — restrict to entities the user can expand,
    /// and (when the entity's type declares `add_from`) further narrow
    /// candidates to types that allow this type as a child. Mirrors webapp's
    /// `parentQuery` in `entity/drawer/parents.vue`.
    private var parentQuery: String {
        guard let userId = auth.currentUserId else { return "" }
        let base = "_expander.reference=\(userId)"

        guard let typeId = entity?.properties["_type"]?.first?.reference,
              let parentTypes = menu.parentTypesByChild[typeId],
              !parentTypes.isEmpty else {
            return base
        }
        if parentTypes.count == 1 {
            return "\(base)&_type.reference=\(parentTypes[0])"
        }
        return "\(base)&_type.reference.in=\(parentTypes.joined(separator: ","))"
    }

    // MARK: - Loading

    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        loadError = nil
        do {
            let response: EntityDetailResponse = try await api.get(
                "entity/\(entityId)",
                params: ["props": "name,_parent,_type"]
            )
            entity = response.entity
            await refreshRemovableParents()
        } catch {
            loadError = String(localized: "networkError", bundle: .currentLocalized)
        }
        if !silent { isLoading = false }
    }

    /// Probe each parent for the active user's `_expander` right in
    /// parallel — webapp does this serially. Failed probes leave the
    /// parent un-removable (no delete button shown).
    private func refreshRemovableParents() async {
        guard let userId = auth.currentUserId else {
            canRemoveParents = []
            return
        }
        let parentIds = parents.compactMap { $0.reference }
        guard !parentIds.isEmpty else {
            canRemoveParents = []
            return
        }

        let removable = await withTaskGroup(of: String?.self) { group in
            for parentId in parentIds {
                group.addTask {
                    let response: EntityDetailResponse? = try? await api.get(
                        "entity/\(parentId)",
                        params: ["props": "_expander"]
                    )
                    let canExpand = response?.entity?.properties["_expander"]?.contains {
                        $0.reference == userId
                    } ?? false
                    return canExpand ? parentId : nil
                }
            }
            var ids: Set<String> = []
            for await id in group { if let id { ids.insert(id) } }
            return ids
        }
        canRemoveParents = removable
    }

    // MARK: - Mutations

    private func addParent(reference: String) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            var change = EntityPropertyChange(type: "_parent")
            change.reference = reference
            let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            await load(silent: true)
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func deleteParent(propertyId: String) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let _: DeleteResponse = try await api.delete("property/\(propertyId)")
            await load(silent: true)
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }
}

private extension PropertyValue {
    /// Stable identity for `ForEach`. `_id` is the property's own id;
    /// fall back to the referenced entity id, then the printable string.
    var uniqueId: String { _id ?? reference ?? string ?? UUID().uuidString }
}
