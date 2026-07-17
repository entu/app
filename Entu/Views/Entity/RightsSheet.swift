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

    /// True while the add-user chip is swapped for the inline picker.
    @State private var pickerActive = false

    /// True once a change has committed — the autosave pill only appears
    /// after an actual save, not on a freshly opened sheet.
    @State private var hasSavedChanges = false

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
            // Changes autosave — the pill replaces a confirm button.
            SheetHeader(title: headerTitle, subtitle: headerSubtitle) {
                if isUpdating || hasSavedChanges {
                    AutosavePill(isSaving: isUpdating)
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

    // MARK: - Title

    private var headerTitle: String {
        String(localized: "rights", bundle: .currentLocalized)
    }

    /// Subtitle: the entity's name, nil when it has none.
    private var headerSubtitle: String? {
        let name = PropertyValue.localized(entity?.properties["name"])
        return (name?.isEmpty == false) ? name : nil
    }

    // MARK: - Form

    private var formBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    #if os(iOS)
                    // No in-content header on iOS (the nav bar carries the
                    // title), so the pill sits above the sections instead.
                    if isUpdating || hasSavedChanges {
                        HStack {
                            Spacer()
                            AutosavePill(isSaving: isUpdating)
                        }
                        .padding(.bottom, 8)
                    }
                    #endif

                    sectionKicker("sharingScope")
                        .padding(.bottom, 6)
                    sharingCards

                    inheritedRightsSection
                    entityRightsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .background(Color("WindowBackground"))
            // The picker sits at the sheet's bottom — bring its field and
            // results panel into view when it opens (and again once the
            // first results/keyboard have landed).
            .onChange(of: pickerActive) {
                scrollToPicker(proxy)
            }
        }
    }

    /// Scroll the add-user picker (field + panel) into view — immediately,
    /// then once more after the results panel has rendered and, on iPad,
    /// the keyboard has settled.
    private func scrollToPicker(_ proxy: ScrollViewProxy) {
        guard pickerActive else { return }

        withAnimation { proxy.scrollTo(Self.pickerAnchor, anchor: .bottom) }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard pickerActive else { return }

            withAnimation { proxy.scrollTo(Self.pickerAnchor, anchor: .bottom) }
        }
    }

    private static let pickerAnchor = "add-user-picker"

    /// Uppercase section kicker — same style as the other sheets' section
    /// titles.
    private func sectionKicker(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .kerning(0.8)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Sharing cards

    // Tint per scope follows the shared sharing-state color language
    // (green = private, yellow = domain, orange = public) — same as the
    // detail view's sharing badge and the webapp's sharing icons.
    private var sharingCards: some View {
        HStack(alignment: .top, spacing: 8) {
            sharingCard(value: "private",
                        label: "sharingPrivate",
                        description: "sharingPrivateDescription",
                        icon: "lock",
                        tint: .green)
            sharingCard(value: "domain",
                        label: "sharingDomain",
                        description: "sharingDomainDescription",
                        icon: "person.2",
                        tint: .yellow)
            sharingCard(value: "public",
                        label: "sharingPublic",
                        description: "sharingPublicDescription",
                        icon: "globe",
                        tint: .orange)
        }
        .frame(maxWidth: .infinity)
    }

    /// One selectable sharing-scope card — tinted icon, title, muted
    /// description. The selected card carries an accent ring instead of
    /// the hairline.
    private func sharingCard(value: String, label: LocalizedStringKey, description: LocalizedStringKey, icon: String, tint: Color) -> some View {
        let isSelected = sharing == value

        return Button {
            guard sharing != value else { return }

            sharing = value
            Task { await updateSharing(to: value) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(tint)

                Text(label)
                    .font(.callout.weight(.semibold))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Rights sections

    @ViewBuilder
    private var inheritedRightsSection: some View {
        // Section header carries the Inherit toggle (disabled when no own
        // rights exist — nothing to override). Rows show only while
        // inheriting, with the centered explainer below.
        HStack(spacing: 6) {
            sectionKicker("userRightsParent")

            Spacer()

            Toggle("inheritRights", isOn: $inheritRights)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.small)
                // iOS toggles stretch to fill the row, dragging the label
                // leftward — hug the label + switch instead (macOS already
                // hugs).
                .fixedSize()
                .disabled(isUpdating || entityRights.isEmpty)
                .onChange(of: inheritRights) { old, new in
                    guard old != new else { return }

                    Task { await updateInheritRights(to: new) }
                }
        }
        // Full 44 here — the sharing cards above carry no row padding
        // (the entity-rights kicker uses 38 + the rows' 6).
        .padding(.top, 44)
        .padding(.bottom, 2)

        if inheritRights {
            ForEach(Array(inheritedRights.enumerated()), id: \.element.id) { index, user in
                rightRow(user: user, editable: false)

                if index < inheritedRights.count - 1 {
                    Divider()
                }
            }

            Text("inheritRightsDescription")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var entityRightsSection: some View {
        sectionKicker("userRightsEntity")
            .padding(.top, 38)
            .padding(.bottom, 2)

        ForEach(Array(entityRights.enumerated()), id: \.element.id) { index, user in
            rightRow(user: user, editable: true)

            if index < entityRights.count - 1 {
                Divider()
            }
        }

        Group {
            if pickerActive {
                InlineReferencePicker(
                    query: "_type.string=person",
                    onSelect: { id, _ in
                        Task { await addRight(userId: id) }
                    },
                    onDismiss: { pickerActive = false }
                )
            } else {
                addUserChip
            }
        }
        .padding(.top, 10)
        .id(Self.pickerAnchor)
    }

    /// Dashed "+ Add user" chip — swaps to the inline reference picker.
    private var addUserChip: some View {
        Button {
            pickerActive = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.caption.weight(.medium))
                Text("selectNewUser")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .overlay {
                Capsule().strokeBorder(
                    .quaternary,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
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
                await editRight(user: user, newType: newType)
            },
            onDelete: { await deleteRight(user: user) }
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
                // The aggregation merges parent-inherited copies into the
                // entity's own right arrays — those carry the *parent's*
                // property id and must not appear as editable rows here
                // (editing one would add a right instead of replacing, and
                // the row would snap back). Webapp parity: rights.vue
                // filters `!x.inherited` the same way. The `_parent_*`
                // arrays are all inherited by definition — keep those.
                if prefix.isEmpty && value.inherited == true { continue }

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
            hasSavedChanges = true
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
            hasSavedChanges = true
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
            hasSavedChanges = true
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func editRight(user: RightUser, newType: String) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            // The API guarantees one right property per user per entity —
            // replacing this one also cleans up any others server-side
            // (`markReplacedUserRightsDeleted` in setEntity).
            var change = EntityPropertyChange(type: "_\(newType)")
            change._id = user._id
            change.reference = user.userId
            let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            await load(silent: true)
            hasSavedChanges = true
            onChanged?()
        } catch {
            await load(silent: true)
        }
    }

    private func deleteRight(user: RightUser) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let _: DeleteResponse = try await api.delete("property/\(user._id)")
            await load(silent: true)
            hasSavedChanges = true
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPhone — the five-segment track with an expanded label doesn't fit
    /// the narrow row; the active level shows its icon only.
    private var showsActiveLabel: Bool {
        #if os(iOS)
        horizontalSizeClass != .compact
        #else
        true
        #endif
    }

    /// Segment frames in the track's coordinate space — lets a drag across
    /// the pill slide the selection (not just taps), like the child-type
    /// segmented control.
    @State private var segmentFrames: [String: CGRect] = [:]

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
        HStack(spacing: 10) {
            // Name over the active level's capability sentence, per the
            // design ("Owner — can view, edit, manage rights and delete").
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: user.name)
                    .lineLimit(1)
                Text(helpKey(for: selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                rightButtonGroup
                    // Inherited rows show the selector read-only, dimmed.
                    .opacity(editable ? 1 : 0.6)
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
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: Self.segmentSize, minHeight: Self.segmentSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityLabel("removeRight")
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Per-segment metrics — compact pointer targets on macOS, taller
    /// touch targets on iPad/iPhone.
    #if os(macOS)
    static let segmentSize: CGFloat = 30
    static let segmentHeight: CGFloat = 26
    #else
    static let segmentSize: CGFloat = 42
    static let segmentHeight: CGFloat = 36
    #endif

    /// The design's level selector (21c): all five levels as icons in a
    /// capsule track, the ACTIVE one expanded into a raised icon + label
    /// pill. Custom buttons instead of `Picker(.segmented)` so each level
    /// carries its own `.help()` tooltip — webapp parity with
    /// `my-rights-switch`'s per-icon tooltip text.
    private var rightButtonGroup: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { type in
                let isActive = selection == type

                Button {
                    guard selection != type else { return }

                    withAnimation(.spring(duration: 0.25)) { selection = type }
                    Task { await onChange(type) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: iconFor(type))
                            .font(.footnote)
                            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                        if isActive && showsActiveLabel {
                            Text(nameKey(for: type))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                // Never truncate the level name — the pill
                                // grows to fit it.
                                .fixedSize()
                                .transition(.opacity)
                        }
                    }
                    .frame(minWidth: isActive && showsActiveLabel ? nil : Self.segmentSize, minHeight: Self.segmentHeight)
                    .padding(.horizontal, isActive && showsActiveLabel ? 11 : 0)
                    .background {
                        if isActive {
                            Capsule()
                                .fill(Color("CardBackground"))
                                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                                .overlay {
                                    Capsule().strokeBorder(Color("CardHairline"), lineWidth: 0.5)
                                }
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(helpKey(for: type))
                .disabled(!editable || disabled)
                .accessibilityLabel(nameKey(for: type))
                .accessibilityHint(helpKey(for: type))
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("rightSegments"))
                } action: { segmentFrames[type] = $0 }
            }
        }
        .padding(2)
        .background(.fill.tertiary, in: Capsule())
        .coordinateSpace(name: "rightSegments")
        // Sliding a finger (or dragging the pointer) across the track moves
        // the selection; the level commits once on release. Taps still work
        // through the buttons.
        .simultaneousGesture(trackDrag)
    }

    private var trackDrag: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rightSegments"))
            .onChanged { value in
                guard editable, !disabled else { return }
                guard let hit = segmentFrames.first(where: {
                    $0.value.minX <= value.location.x && value.location.x <= $0.value.maxX
                })?.key, hit != selection else { return }

                withAnimation(.spring(duration: 0.25)) { selection = hit }
            }
            .onEnded { _ in
                guard editable, !disabled, selection != user.type else { return }

                Task { await onChange(selection) }
            }
    }

    /// Short level name per right level — used as the segment's
    /// accessibility label (the `.help()` sentence stays the hint).
    /// Literal keys for the same xcstrings-extraction reason as `helpKey`.
    private func nameKey(for type: String) -> LocalizedStringKey {
        switch type {
        case "noaccess": return "noaccess"
        case "viewer":   return "viewer"
        case "expander": return "expander"
        case "editor":   return "editor"
        case "owner":    return "owner"
        default:         return ""
        }
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
