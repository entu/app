// Per-entity rights drawer. Mirrors webapp's
// `components/entity/drawer/rights.vue` — shows sharing scope (private /
// domain / public), inherit-rights toggle, list of inherited rights from
// the parent, and the per-user rights table on this entity itself.
//
// Each user is bucketed into the highest right they hold (owner > editor >
// expander > viewer > noaccess). Changing a user's right replaces the
// existing property in place via `_id`; removing it deletes the property.
// Adding a user starts them as viewer (matches webapp default).
//
// Owner-only sheet — visibility is gated by the parent EntityToolbar so
// non-owners never see this.

import SwiftUI

/// Rights / sharing editor for a single entity.
struct RightsSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let entityId: String
    var onChanged: (() -> Void)?

    @State private var entity: EntityDetail?
    @State private var sharing: String = "private"
    @State private var inheritRights: Bool = false
    @State private var isLoading = true
    @State private var isUpdating = false
    @State private var loadError: String?
    @State private var showingPicker = false

    /// Property names loaded for the rights view — sharing flag, inherit
    /// flag, all five right buckets, and parent's inherited rights for
    /// read-only display.
    private static let rightsProps = [
        "name", "_type",
        "_sharing", "_inheritrights",
        "_noaccess", "_viewer", "_expander", "_editor", "_owner",
        "_parent_viewer", "_parent_expander", "_parent_editor", "_parent_owner"
    ].joined(separator: ",")

    /// Right buckets in display order (low → high). The full set is used
    /// for entity-own rights; inherited rights drop `noaccess` because the
    /// API only loads `_parent_owner/_editor/_expander/_viewer` (no
    /// `_parent_noaccess`), so the option could never be the active value.
    private static let rightTypes = ["noaccess", "viewer", "expander", "editor", "owner"]
    private static let inheritedRightTypes = ["viewer", "expander", "editor", "owner"]

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            sheetHeader
            #endif
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                } else {
                    formBody
                }
            }
        }
        #if os(iOS)
        .navigationTitle(Text("rights"))
        .navigationSubtitle(headerSubtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(isDisabled: isUpdating) { dismiss() }
            }
        }
        .task { await load() }
        .appLanguageScoped()
    }

    #if os(macOS)
    /// In-content title bar for macOS sheets. See EntityEditView.swift —
    /// macOS sheets don't render the toolbar's principal slot.
    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("rights")
                .font(.headline)
            if let headerSubtitle, !headerSubtitle.isEmpty {
                Text(verbatim: headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    #endif

    // MARK: - Title

    /// Subtitle: entity name (preferred), fall back to type label.
    private var headerSubtitle: String? {
        if let name = PropertyValue.localized(entity?.properties["name"]), !name.isEmpty {
            return name
        }
        return entity?.typeName
    }

    // MARK: - Form

    private var formBody: some View {
        Form {
            sharingSection
            inheritedRightsSection
            entityRightsSection
        }
        .formStyle(.grouped)
    }

    private var sharingSection: some View {
        Section("sharingScope") {
            sharingOption(value: "private",
                          label: "sharingPrivate",
                          description: "sharingPrivateDescription",
                          icon: "lock",
                          tint: .red)
            sharingOption(value: "domain",
                          label: "sharingDomain",
                          description: "sharingDomainDescription",
                          icon: "person.2",
                          tint: .orange)
            sharingOption(value: "public",
                          label: "sharingPublic",
                          description: "sharingPublicDescription",
                          icon: "globe",
                          tint: .green)
        }
    }

    /// Single sharing-scope row — radio dot + tinted sharing icon (both
    /// vertically centred against the title/description block) + title
    /// with a muted description below. Custom layout because SwiftUI's
    /// `Picker(.inline)` renders only the title and `Label`'s default
    /// style left-aligns the description with the icon.
    private func sharingOption(value: String, label: LocalizedStringKey, description: LocalizedStringKey, icon: String, tint: Color) -> some View {
        Button {
            guard sharing != value else { return }
            sharing = value
            Task { await updateSharing(to: value) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: sharing == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(sharing == value ? Color.accentColor : .secondary)
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
    }

    @ViewBuilder
    private var inheritedRightsSection: some View {
        // Read-only inherited rights from the parent at the top, then the
        // toggle + description at the bottom. Toggle is disabled when no
        // own rights exist (nothing to override).
        Section("userRightsParent") {
            if inheritRights {
                ForEach(inheritedRights) { user in
                    rightRow(user: user, editable: false)
                }
            }
            Toggle("inheritRights", isOn: $inheritRights)
                .disabled(isUpdating || entityRights.isEmpty)
                .onChange(of: inheritRights) { old, new in
                    guard old != new else { return }
                    Task { await updateInheritRights(to: new) }
                }
            if inheritRights {
                Text("inheritRightsDescription")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var entityRightsSection: some View {
        Section("userRightsEntity") {
            ForEach(entityRights) { user in
                rightRow(user: user, editable: true)
            }
            Button {
                showingPicker = true
            } label: {
                Label("selectNewUser", systemImage: "person.badge.plus")
            }
            .disabled(isUpdating)
            .sheet(isPresented: $showingPicker) {
                NavigationStack {
                    ReferencePickerView(
                        query: "_type.string=person",
                        subtitle: String(localized: "rights", bundle: .currentLocalized)
                    ) { id, _ in
                        showingPicker = false
                        Task { await addRight(userId: id) }
                    }
                }
            }
        }
    }

    /// Single user row: name + 5-button right selector + delete affordance.
    /// `editable == false` for inherited rights — selector + delete are
    /// disabled. Extracted so the picker's selection can hold local state
    /// (segmented Picker bound through `Binding(get:set:)` reverts visually
    /// when the setter goes async — local @State updates optimistically).
    private func rightRow(user: RightUser, editable: Bool) -> some View {
        RightRow(
            user: user,
            editable: editable,
            disabled: isUpdating || user.userId == auth.currentUserId,
            options: editable ? Self.rightTypes : Self.inheritedRightTypes,
            iconFor: rightIcon,
            onChange: { newType in
                await editRight(propertyId: user._id, userId: user.userId, newType: newType)
            },
            onDelete: { await deleteRight(propertyId: user._id) }
        )
    }

    /// SF Symbol per right level — visually similar to webapp's
    /// `rights-noaccess/viewer/expander/editor/owner` icon set.
    private func rightIcon(_ type: String) -> String {
        switch type {
        case "noaccess": return "nosign"
        case "viewer":   return "eye"
        case "expander": return "plus.square.on.square"
        case "editor":   return "pencil"
        case "owner":    return "lock.fill"
        default:         return "questionmark"
        }
    }

    // MARK: - Bucketed rights

    /// One user's resolved rights row.
    struct RightUser: Identifiable {
        let _id: String        // the property's `_id`
        let userId: String     // the referenced person entity id
        let name: String
        let type: String       // bucketed: noaccess/viewer/expander/editor/owner
        var id: String { _id }
    }

    /// Per-user rights on this entity — bucketed into the highest right
    /// they hold. Mirrors webapp's `entityRights` computed.
    private var entityRights: [RightUser] {
        guard let entity else { return [] }
        return resolveRights(prefix: "", from: entity)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Inherited rights from the parent entity (read-only display).
    /// Mirrors webapp: users blocked via this entity's `_noaccess` still
    /// appear here — the inherited list is informational ("rights granted
    /// by parent"), separate from the noaccess override on this entity.
    private var inheritedRights: [RightUser] {
        guard let entity else { return [] }
        return resolveRights(prefix: "_parent", from: entity)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Walk the bucketed rights from highest to lowest, dropping any user
    /// already counted in a stronger bucket. `prefix` is "" for entity's
    /// own rights or "_parent" for inherited rights from the parent entity.
    /// Parent (inherited) rights have no `_noaccess` bucket — the API
    /// doesn't surface `_parent_noaccess` and we don't load it.
    private func resolveRights(prefix: String, from entity: EntityDetail) -> [RightUser] {
        var buckets: [(key: String, type: String)] = [
            ("\(prefix)_owner",    "owner"),
            ("\(prefix)_editor",   "editor"),
            ("\(prefix)_expander", "expander"),
            ("\(prefix)_viewer",   "viewer")
        ]
        if prefix.isEmpty {
            buckets.append(("_noaccess", "noaccess"))
        }
        var seen: Set<String> = []
        var users: [RightUser] = []
        for (key, type) in buckets {
            for value in entity.properties[key] ?? [] {
                guard let propertyId = value._id, let userId = value.reference else { continue }
                if seen.contains(userId) { continue }
                seen.insert(userId)
                users.append(RightUser(
                    _id: propertyId,
                    userId: userId,
                    name: value.string ?? userId,
                    type: type
                ))
            }
        }
        return users
    }

    // MARK: - Loading

    /// Initial load shows the spinner; mutation refreshes call with
    /// `silent: true` so the form stays on screen and the data updates
    /// in place — otherwise every change flickers through `ProgressView`.
    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        loadError = nil
        do {
            let response: EntityDetailResponse = try await api.get(
                "entity/\(entityId)",
                params: ["props": Self.rightsProps]
            )
            entity = response.entity
            sharing = entity?.properties["_sharing"]?.first?.string ?? "private"
            inheritRights = entity?.properties["_inheritrights"]?.first?.boolean ?? false
        } catch {
            loadError = String(localized: "networkError", bundle: .currentLocalized)
        }
        if !silent { isLoading = false }
    }

    // MARK: - Mutations

    private func updateSharing(to value: String) async {
        isUpdating = true
        defer { isUpdating = false }
        let propertyId = entity?.properties["_sharing"]?.first?._id
        do {
            if value == "private" {
                if let propertyId {
                    let _: DeleteResponse = try await api.delete("property/\(propertyId)")
                }
            } else {
                var change = EntityPropertyChange(type: "_sharing")
                change._id = propertyId
                change.string = value
                let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            }
            await load(silent: true)
            onChanged?()
        } catch {
            await load()  // resync UI to server truth on failure
        }
    }

    private func updateInheritRights(to value: Bool) async {
        isUpdating = true
        defer { isUpdating = false }
        let propertyId = entity?.properties["_inheritrights"]?.first?._id
        do {
            if value {
                var change = EntityPropertyChange(type: "_inheritrights")
                change._id = propertyId
                change.boolean = true
                let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            } else if let propertyId {
                let _: DeleteResponse = try await api.delete("property/\(propertyId)")
            }
            await load(silent: true)
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func addRight(userId: String) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            var change = EntityPropertyChange(type: "_viewer")
            change.reference = userId
            let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            await load(silent: true)
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func editRight(propertyId: String, userId: String, newType: String) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            var change = EntityPropertyChange(type: "_\(newType)")
            change._id = propertyId
            change.reference = userId
            let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            await load(silent: true)
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func deleteRight(propertyId: String) async {
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

/// Per-user rights row. Local `@State` for the picker selection so a tap
/// updates the segment immediately — without that, `Picker` reads its
/// binding's `get` synchronously after `set` returns and reverts the
/// visual selection because the async API round-trip hasn't refreshed
/// `user.type` yet.
private struct RightRow: View {
    let user: RightsSheet.RightUser
    let editable: Bool
    let disabled: Bool
    let options: [String]
    let iconFor: (String) -> String
    let onChange: (String) async -> Void
    let onDelete: () async -> Void

    @State private var selection: String

    init(user: RightsSheet.RightUser,
         editable: Bool,
         disabled: Bool,
         options: [String],
         iconFor: @escaping (String) -> String,
         onChange: @escaping (String) async -> Void,
         onDelete: @escaping () async -> Void) {
        self.user = user
        self.editable = editable
        self.disabled = disabled
        self.options = options
        self.iconFor = iconFor
        self.onChange = onChange
        self.onDelete = onDelete
        _selection = State(initialValue: user.type)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: user.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                rightButtonGroup
                    .onChange(of: user.type) { _, new in
                        // Server refreshed and bumped the row's type from
                        // outside (e.g. `editRight` completed → parent reloaded).
                        // Sync the local selection so it stays in lockstep.
                        if new != selection { selection = new }
                    }

                if editable {
                    Button(role: .destructive) {
                        Task { await onDelete() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                    .disabled(disabled)
                }
            }
        }
    }

    /// Custom button group instead of `Picker(.segmented)` so each level
    /// can carry its own `.help()` tooltip — webapp parity with
    /// `my-rights-switch`'s per-icon tooltip text.
    private var rightButtonGroup: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { type in
                Button {
                    guard selection != type else { return }
                    selection = type
                    Task { await onChange(type) }
                } label: {
                    Image(systemName: iconFor(type))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .foregroundStyle(selection == type ? Color.white : Color.primary)
                        .background(selection == type ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)
                .help(helpKey(for: type))
                .disabled(!editable || disabled)
            }
        }
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Static `LocalizedStringKey` per right level. Xcode's xcstrings
    /// extractor only sees literal keys, so `.help()` would not localize a
    /// runtime-interpolated key — switch to keep them all literal.
    private func helpKey(for type: String) -> LocalizedStringKey {
        switch type {
        case "noaccess": return "rightsNoaccessHelp"
        case "viewer":   return "rightsViewerHelp"
        case "expander": return "rightsExpanderHelp"
        case "editor":   return "rightsEditorHelp"
        case "owner":    return "rightsOwnerHelp"
        default:         return ""
        }
    }
}
