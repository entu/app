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

    /// Types that can be added at the top of the active menu — same data
    /// the list-column toolbar's Add uses, surfaced here too.
    private var menuLevelAddTypes: [AddFromType] {
        guard let menuId else { return [] }
        return menu.addFromTypes[menuId] ?? []
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
        #if os(macOS)
        // Last in this block → renders immediately left of the system
        // search field, ungrouped from the entity buttons. On iOS the
        // equivalent button lives in the list column's toolbar.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            advancedSearchButton
        }
        #endif
    }

    // MARK: - Buttons

    #if os(macOS)
    /// Opens the advanced-search sheet (hosted by `MainView`). Hidden in
    /// public-database mode — webapp gates the whole search UI on a
    /// signed-in user.
    @ViewBuilder
    private var advancedSearchButton: some View {
        if SearchModel.showAdvancedButton, auth.currentUserId != nil {
            Button {
                search.showAdvanced = true
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
    #endif

    @ViewBuilder
    private var menuLevelAddButton: some View {
        // Hidden in public-database mode (currentUserId == nil) — the API
        // would reject the POST anyway.
        if auth.currentUserId != nil && !menuLevelAddTypes.isEmpty {
            if menuLevelAddTypes.count == 1, let only = menuLevelAddTypes.first {
                Button {
                    editMode = .create(parentId: nil, typeId: only._id, typeLabel: only.label)
                } label: {
                    Label {
                        Text("addOne \(only.label.lowercased())")
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            } else {
                Menu {
                    ForEach(menuLevelAddTypes) { type in
                        Button(type.label.lowercased()) {
                            editMode = .create(parentId: nil, typeId: type._id, typeLabel: type.label)
                        }
                    }
                } label: {
                    Label("add", systemImage: "square.and.pencil")
                }
            }
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
                Label("parents", systemImage: "arrow.triangle.branch")
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
        menuId: String? = nil,
        onEdited: (() -> Void)? = nil,
        onCreated: ((String) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onListChanged: (() -> Void)? = nil
    ) -> some View {
        modifier(EntityToolbarHost(
            entity: entity,
            menuId: menuId,
            onEdited: onEdited,
            onCreated: onCreated,
            onDelete: onDelete,
            onListChanged: onListChanged
        ))
    }
}

private struct EntityToolbarHost: ViewModifier {
    @Environment(APIClient.self) private var api
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu
    @Environment(DeepLinkRouter.self) private var router

    let entity: EntityDetail
    let menuId: String?
    let onEdited: (() -> Void)?
    let onCreated: ((String) -> Void)?
    let onDelete: (() -> Void)?
    let onListChanged: (() -> Void)?

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
                width: 560, height: 600
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
                    entityName: entity.displayName,
                    typeLabel: entity.typeName
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
                .presentationDetents([.large])
            }
            // A plugin redirect to `entu.app/{db}/{id}#edit` opens the entity
            // in edit mode (webapp parity). The deep link already navigated
            // here; when this entity appears, honor the pending edit request.
            .onAppear { openPendingEditIfNeeded() }
    }

    /// The current entity's rights-gated action set for the `Entity` menu.
    /// Gates match `EntityToolbar`'s buttons exactly.
    private var entityActions: EntityActions {
        let rights = entity.rights(for: auth.currentUserId)
        return EntityActions(
            edit: rights.editor ? { editMode = .edit(entityId: entity._id) } : nil,
            duplicate: rights.owner ? { showingDuplicate = true } : nil,
            parents: rights.editor ? { showingParents = true } : nil,
            rights: rights.owner ? { showingRights = true } : nil,
            history: rights.editor ? { showingHistory = true } : nil
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

        return EntityCreateCommand(options: options) {
            if options.count == 1 {
                options[0].create()
            } else {
                showAddChildPicker = true
            }
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
private struct SheetMinSize: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            content
        } else {
            content.frame(minWidth: width, minHeight: height)
        }
        #else
        content.frame(minWidth: width, minHeight: height)
        #endif
    }
}

extension View {
    fileprivate func sheetMinSize(width: CGFloat, height: CGFloat) -> some View {
        modifier(SheetMinSize(width: width, height: height))
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
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: {
            if didChange.wrappedValue {
                onChange?()
                didChange.wrappedValue = false
            }
        }) {
            NavigationStack {
                content()
                    .sheetMinSize(width: width, height: height)
            }
            .presentationDetents([.large])
        }
    }
}
