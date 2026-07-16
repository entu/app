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

    /// True once a change has committed — the "All changes saved" pill
    /// only appears after an actual save, not on a freshly opened sheet.
    @State private var hasSavedChanges = false
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
            // Changes autosave — the pill replaces a confirm button.
            SheetHeader(title: headerTitle, subtitle: headerSubtitle) {
                if isUpdating || hasSavedChanges {
                    autosavePill
                }
            }
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

    /// Autosave status — green "All changes saved" once idle, a quiet
    /// "Saving…" while a mutation is in flight.
    private var autosavePill: some View {
        HStack(spacing: 5) {
            if isUpdating {
                ProgressView()
                    .controlSize(.mini)
                Text("saving")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                Text("allChangesSaved")
            }
        }
        .font(.caption)
        .foregroundStyle(Color("SuccessText"))
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .background(
            (isUpdating ? Color.secondary : Color.green).opacity(0.14),
            in: Capsule()
        )
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
        ScrollView {
            VStack(spacing: 6) {
                #if os(iOS)
                // No in-content header on iOS (the nav bar carries the
                // title), so the pill sits above the rows instead. Toolbar
                // placement is out — toolbar items get button chrome.
                if isUpdating || hasSavedChanges {
                    HStack {
                        Spacer()
                        autosavePill
                    }
                    .padding(.bottom, 4)
                }
                #endif

                ForEach(parents, id: \.self.uniqueId) { parent in
                    parentRow(parent)
                }

                addParentRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(Color("WindowBackground"))
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

    /// One parent as a white card row — folder icon, name, remove ×
    /// (shown only for parents the user holds `_expander` on).
    @ViewBuilder
    private func parentRow(_ parent: PropertyValue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.folder")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Text(verbatim: parent.string ?? parent.reference ?? "")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let propertyId = parent._id,
               let parentId = parent.reference,
               canRemoveParents.contains(parentId) {
                Button(role: .destructive) {
                    Task { await deleteParent(propertyId: propertyId) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        // Small glyph, comfortable target.
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
                .accessibilityLabel(Text("delete"))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
        }
    }

    /// Dashed ghost row — opens the reference picker.
    private var addParentRow: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.footnote.weight(.medium))
                Text("selectNewParent")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        .quaternary,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
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
            hasSavedChanges = true
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
            hasSavedChanges = true
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
