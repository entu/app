// Rights-gated toolbar for `EntityDetailView`. Buttons hide when the
// active user lacks the required right (and entirely in public mode,
// where `currentUserId` is nil and every right is false).
//
// Edit and Add child open `EntityEditView` as a sheet — the sheet
// autosaves on blur and owns its own Delete button, so this toolbar has
// no Delete. Duplicate / parents / rights / history are also functional
// sheets; on iPhone (compact width) they collapse into the system "..."
// overflow menu via `secondaryPlacement`.

import SwiftUI

/// Types that can be added under `entity`. Mirrors the webapp's
/// `addChildOptions`: prefer `addFromTypes[entity._id]`, skipping the
/// `entity`/`menu` meta-types, then fall back to the type's allow-list.
/// Shared by the toolbar's Add-child button and the File > Add Child
/// menu command (via `EntityToolbarHost`).
@MainActor
func entityAddChildTypes(for entity: EntityDetail, menu: MenuModel) -> [AddFromType] {
    let typeName = entity.typeName?.lowercased() ?? ""
    let isMetaType = typeName == "entity" || typeName == "menu"

    if !isMetaType {
        let byEntity = menu.addFromTypes[entity._id] ?? []
        if !byEntity.isEmpty { return byEntity }
    }
    if let typeId = entity.typeId {
        return menu.addFromTypes[typeId] ?? []
    }
    return []
}

/// Menu-level Add button — shared by the live toolbar and the loading
/// placeholder, since its visibility depends only on the active menu, not
/// the entity. `onCreate == nil` renders the disabled placeholder variant.
private struct MenuLevelAddButton: View {
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu

    let menuId: String?
    var onCreate: ((AddFromType) -> Void)?

    private var types: [AddFromType] {
        guard let menuId else { return [] }
        return menu.addFromTypes[menuId] ?? []
    }

    var body: some View {
        // Hidden in public-database mode (currentUserId == nil) — the API
        // would reject the POST anyway.
        if auth.currentUserId != nil && !types.isEmpty {
            Group {
                if types.count == 1, let only = types.first {
                    Button {
                        onCreate?(only)
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
                                onCreate?(type)
                            }
                        }
                    } label: {
                        Label("add", systemImage: "square.and.pencil")
                    }
                }
            }
            .disabled(onCreate == nil)
        }
    }
}

#if os(macOS)
/// Disabled stand-in shown while an entity loads — keeps the window
/// toolbar's layout stable (without it the section collapses or narrows:
/// the list's advanced-search item jumps next to the search field, the
/// buttons flicker, and the cluster drifts). Mirrors the live toolbar's
/// structure; back stays functional so a slow load can be escaped.
struct EntityToolbarPlaceholder: ToolbarContent {
    var onBack: (() -> Void)?
    var menuId: String?

    var body: some ToolbarContent {
        if let onBack {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onBack) {
                    Label("back", systemImage: "chevron.left")
                }
            }
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            MenuLevelAddButton(menuId: menuId)
        }
        // No add-child stand-in: its visibility needs the loaded entity's
        // rights, and a phantom "+" that may vanish reads worse than the
        // small cluster shift when the real one appears.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {} label: {
                Label("edit", systemImage: "pencil")
            }
            .disabled(true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {} label: { Label("duplicate", systemImage: "doc.on.doc") }
                .disabled(true)
            Button {} label: { Label("parents", systemImage: "arrow.up.folder") }
                .disabled(true)
            Button {} label: { Label("rights", systemImage: "person.2") }
                .disabled(true)
            Button {} label: { Label("history", systemImage: "clock.arrow.circlepath") }
                .disabled(true)
        }
    }
}
#endif

/// Edit / Add / Duplicate / Parents / Rights / History buttons. Each
/// opens a feature sheet via its corresponding `@Binding` flag, set
/// from `EntityToolbarHost`.
private struct EntityToolbar: ToolbarContent {
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @Environment(SearchModel.self) private var search
    #endif

    let entity: EntityDetail
    let menuId: String?
    /// Pops the entity drill-down history — the toolbar's first (leading)
    /// pill on macOS; iOS uses the nav-bar back position instead.
    var onBack: (() -> Void)?
    @Binding var editMode: EntityEditMode?
    @Binding var showingRights: Bool
    @Binding var showingParents: Bool
    @Binding var showingDuplicate: Bool
    @Binding var showingHistory: Bool

    /// Compact (iPhone) → `.secondaryAction` collapses into the "..." menu;
    /// regular (iPad / macOS) → `.primaryAction` keeps them inline.
    private var secondaryPlacement: ToolbarItemPlacement {
        #if os(iOS)
        horizontalSizeClass == .compact ? .secondaryAction : .primaryAction
        #else
        .primaryAction
        #endif
    }

    private var rights: EntityRights {
        entity.rights(for: auth.currentUserId)
    }

    /// Types that can be added under this entity. Mirrors webapp's
    /// `addChildOptions`: prefer `addFromTypes[entity._id]`, skipping the
    /// `entity`/`menu` meta-types, then fall back to the type's allow-list.
    private var addChildTypes: [AddFromType] {
        entityAddChildTypes(for: entity, menu: menu)
    }

    var body: some ToolbarContent {
        // Order mirrors webapp's `entity/toolbar.vue`. `ToolbarSpacer(.fixed)`
        // keeps the groups visually distinct on macOS — without it they merge
        // into one pill.
        #if os(macOS)
        if let onBack {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onBack) {
                    Label("back", systemImage: "chevron.left")
                }
            }
        }
        // Back stays at the section's leading edge; the flexible spacer
        // pushes the action pills right, next to the search field, keeping
        // the header's left side clear like the design.
        ToolbarSpacer(.flexible, placement: .primaryAction)
        #endif
        ToolbarItem(placement: .primaryAction) {
            menuLevelAddButton
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            addChildButton
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            editButton
        }
        ToolbarItemGroup(placement: secondaryPlacement) {
            duplicateButton
            parentsButton
            rightsButton
            historyButton
        }
    }

    // MARK: - Buttons

    private var menuLevelAddButton: some View {
        MenuLevelAddButton(menuId: menuId) { type in
            editMode = .create(parentId: nil, typeId: type._id, typeLabel: type.label)
        }
    }

    @ViewBuilder
    private var addChildButton: some View {
        if rights.expander && !addChildTypes.isEmpty {
            if addChildTypes.count == 1, let only = addChildTypes.first {
                Button {
                    editMode = .create(parentId: entity._id, typeId: only._id, typeLabel: only.label)
                } label: {
                    Label {
                        Text("addOneChild \(only.label.lowercased())")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } else {
                Menu {
                    ForEach(addChildTypes) { type in
                        Button(type.label.lowercased()) {
                            editMode = .create(parentId: entity._id, typeId: type._id, typeLabel: type.label)
                        }
                    }
                } label: {
                    Label("addChild", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var editButton: some View {
        if rights.editor {
            Button {
                editMode = .edit(entityId: entity._id)
            } label: {
                Label("edit", systemImage: "pencil")
            }
        }
    }

    // MARK: - Secondary actions (collapse into "..." on iPhone)

    @ViewBuilder
    private var duplicateButton: some View {
        if rights.owner {
            Button {
                showingDuplicate = true
            } label: {
                Label("duplicate", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var parentsButton: some View {
        if rights.editor {
            Button {
                showingParents = true
            } label: {
                Label("parents", systemImage: "arrow.up.folder")
            }
        }
    }

    @ViewBuilder
    private var rightsButton: some View {
        if rights.owner {
            Button {
                showingRights = true
            } label: {
                Label("rights", systemImage: "person.2")
            }
        }
    }

    @ViewBuilder
    private var historyButton: some View {
        if rights.editor {
            Button {
                showingHistory = true
            } label: {
                Label("history", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

extension View {
    /// Attach the entity toolbar plus its edit/create sheet and confirmation
    /// dialogs. Used by `EntityDetailView`.
    func entityToolbarHost(
        entity: EntityDetail,
        typeLabel: String? = nil,
        menuId: String? = nil,
        onBack: (() -> Void)? = nil,
        onEdited: (() -> Void)? = nil,
        onCreated: ((String) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onListChanged: (() -> Void)? = nil,
        onReload: (() -> Void)? = nil
    ) -> some View {
        modifier(EntityToolbarHost(
            entity: entity,
            typeLabel: typeLabel,
            menuId: menuId,
            onBack: onBack,
            onEdited: onEdited,
            onCreated: onCreated,
            onDelete: onDelete,
            onListChanged: onListChanged,
            onReload: onReload
        ))
    }
}

private struct EntityToolbarHost: ViewModifier {
    @Environment(APIClient.self) private var api
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu
    @Environment(DeepLinkRouter.self) private var router
    @Environment(WindowState.self) private var windowState

    let entity: EntityDetail
    /// Localized type label for the palette's "type · name" section title.
    let typeLabel: String?
    let menuId: String?
    let onBack: (() -> Void)?
    let onEdited: (() -> Void)?
    let onCreated: ((String) -> Void)?
    let onDelete: (() -> Void)?
    let onListChanged: (() -> Void)?

    /// View > Reload Entity (⌘R) — refetches the entity and its type
    /// metadata from the API, bypassing the type cache.
    let onReload: (() -> Void)?

    @State private var editMode: EntityEditMode?

    /// Buffered until sheet dismiss: firing `onEdited`/`onCreated` mid-session
    /// would refetch the parent entity, drop the host modifier, and dismiss
    /// the sheet the user is still typing into.
    @State private var pendingCreatedId: String?
    @State private var didEditExisting = false
    @State private var showingRights = false
    @State private var didChangeRights = false
    @State private var showingParents = false
    @State private var didChangeParents = false
    @State private var showingDuplicate = false
    @State private var didDuplicate = false
    @State private var showingHistory = false

    /// Presents the child-type chooser when ⌃⌘N fires and the entity has
    /// more than one addable child type. `pendingChildType` holds the chosen
    /// type until the picker dismisses, then opens the editor for it.
    @State private var showAddChildPicker = false
    @State private var pendingChildType: EntityCreateOption?

    func body(content: Content) -> some View {
        content
            .toolbar {
                EntityToolbar(
                    entity: entity,
                    menuId: menuId,
                    onBack: onBack,
                    editMode: $editMode,
                    showingRights: $showingRights,
                    showingParents: $showingParents,
                    showingDuplicate: $showingDuplicate,
                    showingHistory: $showingHistory
                )
            }
            // Menu-bar / keyboard mirror of the toolbar buttons — same
            // rights gating, same sheet state. See `EntityCommands`.
            .focusedSceneValue(\.entityActions, entityActions)
            // File > Add Child (⌃⌘N) — same expander gating and create-sheet
            // state as the toolbar's Add-child button.
            .focusedSceneValue(\.addChildCommand, addChildCommand)
            // ⌃⌘N with several child types opens this chooser. Title matches
            // the create window's header (`titleChildBare`) so the picker and
            // the editor it opens read the same. The chosen type's create runs
            // on dismiss so the editor sheet doesn't present while the picker
            // is still closing.
            .sheet(isPresented: $showAddChildPicker, onDismiss: {
                if let option = pendingChildType {
                    pendingChildType = nil
                    option.create()
                }
            }) {
                TypePickerSheet(title: "titleChildBare", options: childAddOptions) { chosen in
                    pendingChildType = chosen
                }
            }
            // Sheet hosts use `entitySheet(...)` so each one gets the same
            // chrome (NavigationStack + sheetMinSize + .large detent) and
            // the same buffered-onChanged → fire-on-dismiss callback path.
            // The buffer prevents mid-session refetches from dropping this
            // host modifier and dismissing the sheet the user is editing.
            // History is read-only — no didChange flag, no callback.
            .entitySheet(
                isPresented: $showingRights,
                didChange: $didChangeRights,
                onChange: onEdited,
                width: 600, height: 600,
                wide: true,
                exactWidth: true
            ) {
                RightsSheet(entityId: entity._id, onChanged: { didChangeRights = true })
            }
            .entitySheet(
                isPresented: $showingParents,
                didChange: $didChangeParents,
                onChange: onEdited,
                width: 500, height: 500
            ) {
                ParentsSheet(entityId: entity._id, onChanged: { didChangeParents = true })
            }
            // Duplicate creates *new* sibling entities — the current detail
            // view is unchanged but the surrounding list (middle column /
            // children section) refetches via `onListChanged` to show them.
            .entitySheet(
                isPresented: $showingDuplicate,
                didChange: $didDuplicate,
                onChange: onListChanged,
                width: 500, height: 600
            ) {
                DuplicateSheet(entityId: entity._id, onDuplicated: { didDuplicate = true })
            }
            .entitySheet(
                isPresented: $showingHistory,
                didChange: .constant(false),
                onChange: nil,
                width: 600, height: 600
            ) {
                HistorySheet(
                    entityId: entity._id,
                    typeId: entity.typeId,
                    entityName: entity.displayName
                )
            }
            .sheet(
                item: $editMode,
                onDismiss: {
                    if let id = pendingCreatedId {
                        onCreated?(id)
                    }
                    if didEditExisting {
                        onEdited?()
                    }
                    pendingCreatedId = nil
                    didEditExisting = false
                }
            ) { mode in
                NavigationStack {
                    EntityEditView(
                        mode: mode,
                        onSaved: { savedId in
                            switch mode {
                            case .edit:
                                didEditExisting = true
                            case .create:
                                pendingCreatedId = savedId
                            }
                        },
                        onDeleted: {
                            EntityDetailModel.clearCache()
                            editMode = nil
                            onDelete?()
                        }
                    )
                    // Form sheet auto-sizes to content; pin a wider minimum
                    // on iPad / macOS so two-column property rows don't
                    // squeeze. iPhone (compact) skips the min so the sheet
                    // matches the screen width and rows don't clip.
                    .sheetMinSize(width: 640, height: 600)
                }
                .blocksCommandPalette()
                // Wider page-sheet sizing on iPad (same as Rights) — the
                // two-column rows need the room.
                .presentationSizing(.page)
            }
            // A plugin redirect to `entu.app/{db}/{id}#edit` opens the entity
            // in edit mode (webapp parity). The deep link already navigated
            // here; when this entity appears, honor the pending edit request.
            // Row context menus use the same channel: they select the row
            // and stash the requested action for when the entity is loaded.
            .onAppear {
                openPendingEditIfNeeded()
                openPendingRowActionIfNeeded()
            }
            .onChange(of: router.pendingRowAction) {
                openPendingRowActionIfNeeded()
            }
    }

    /// The current entity's rights-gated action set for the `Entity` menu.
    /// Gates match `EntityToolbar`'s buttons exactly.
    private var entityActions: EntityActions {
        let rights = entity.rights(for: auth.currentUserId)
        return EntityActions(
            windowId: windowState.windowId,
            entityId: entity._id,
            entityName: entity.displayName,
            entityTypeLabel: typeLabel ?? entity.typeName,
            edit: rights.editor ? { editMode = .edit(entityId: entity._id) } : nil,
            duplicate: rights.owner ? { showingDuplicate = true } : nil,
            parents: rights.editor ? { showingParents = true } : nil,
            rights: rights.owner ? { showingRights = true } : nil,
            history: rights.editor ? { showingHistory = true } : nil,
            reload: onReload
        )
    }

    /// Add-child options — expander-gated, one per addable child type, each
    /// opening the create sheet parented to this entity.
    private var childAddOptions: [EntityCreateOption] {
        guard entity.rights(for: auth.currentUserId).expander else { return [] }

        return entityAddChildTypes(for: entity, menu: menu).map { type in
            EntityCreateOption(id: type._id, label: type.label, menuLabel: type.englishLabel) {
                editMode = .create(parentId: entity._id, typeId: type._id, typeLabel: type.label)
            }
        }
    }

    /// File > Add Child (⌃⌘N) command. `nil` (not empty) when unavailable so
    /// the menu item disappears. One type → the shortcut creates it directly;
    /// several → it opens the type chooser.
    private var addChildCommand: EntityCreateCommand? {
        let options = childAddOptions
        guard !options.isEmpty else { return nil }

        return EntityCreateCommand(windowId: windowState.windowId, options: options) {
            if options.count == 1 {
                options[0].create()
            } else {
                showAddChildPicker = true
            }
        }
    }

    /// Consume a context-menu action once its entity is the loaded detail —
    /// same rights gating as the toolbar buttons; lacking the right, the
    /// action is dropped silently (the row stays selected).
    private func openPendingRowActionIfNeeded() {
        guard let pending = router.pendingRowAction, pending.entityId == entity._id else { return }

        router.pendingRowAction = nil
        let rights = entity.rights(for: auth.currentUserId)
        switch pending.kind {
        case .edit:
            if rights.editor { editMode = .edit(entityId: entity._id) }
        case .duplicate:
            if rights.owner { showingDuplicate = true }
        case .parents:
            if rights.editor { showingParents = true }
        case .rights:
            if rights.owner { showingRights = true }
        case .history:
            if rights.editor { showingHistory = true }
        }
    }

    /// Present the editor once for an entity the deep link flagged with
    /// `#edit`, then clear the flag so manual revisits don't re-open it.
    private func openPendingEditIfNeeded() {
        guard router.pendingEditEntityId == entity._id else { return }

        router.pendingEditEntityId = nil
        editMode = .edit(entityId: entity._id)
    }
}

/// Apply `.frame(minWidth:minHeight:)` only on regular size class
/// (iPad / macOS) so iPhone sheets don't force a width wider than the
/// screen — which would horizontally clip the form rows.
///
/// `exactWidth` pins the macOS width instead of setting a floor — macOS
/// sheets otherwise grow to the content's *ideal* width, so a sheet with
/// long single-line texts (Rights' capability sentences) can never get
/// narrower than their unwrapped width via `minWidth` alone.
private struct SheetMinSize: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    let width: CGFloat
    let height: CGFloat
    var exactWidth = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            content
        } else {
            content.frame(minWidth: width, minHeight: height)
        }
        #else
        if exactWidth {
            content
                .frame(width: width)
                .frame(minHeight: height)
        } else {
            content.frame(minWidth: width, minHeight: height)
        }
        #endif
    }
}

extension View {
    fileprivate func sheetMinSize(width: CGFloat, height: CGFloat, exactWidth: Bool = false) -> some View {
        modifier(SheetMinSize(width: width, height: height, exactWidth: exactWidth))
    }

    /// Standard chrome for an entity-feature sheet: NavigationStack +
    /// `sheetMinSize` + `.large` detent. The buffered `didChange` flag
    /// fires `onChange` only on dismiss — calling the parent's refresh
    /// callback mid-session would refetch the entity, drop this host
    /// modifier, and dismiss the sheet the user is editing. History-style
    /// read-only sheets pass `didChange: .constant(false)` and `onChange: nil`.
    fileprivate func entitySheet<Content: View>(
        isPresented: Binding<Bool>,
        didChange: Binding<Bool>,
        onChange: (() -> Void)?,
        width: CGFloat,
        height: CGFloat,
        wide: Bool = false,
        exactWidth: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: {
            if didChange.wrappedValue {
                onChange?()
                didChange.wrappedValue = false
            }
        }) {
            let stack = NavigationStack {
                content()
                    .sheetMinSize(width: width, height: height, exactWidth: exactWidth)
                    .blocksCommandPalette()
            }

            // iPad sheet widths are system-fixed — `wide` opts into the
            // broader page-sheet sizing (Rights, with its three cards +
            // level selectors). macOS width comes from `sheetMinSize`.
            if wide {
                stack.presentationSizing(.page)
            } else {
                stack.presentationDetents([.large])
            }
        }
    }
}
