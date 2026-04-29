// Rights-gated action toolbar for `EntityDetailView`.
//
// Renders Edit / Add child buttons, each visible only when the active user
// holds the required right on this entity. In a public-database session
// there is no current user, so both buttons hide automatically via
// `EntityRights`. Whole-entity Delete lives inside `EntityEditView`'s
// destructive footer instead of the toolbar — keeps the destructive
// affordance close to the form-level edit context (Apple Mail / Calendar
// pattern).
//
// Edit and Add child open `EntityEditView` as a `.sheet` — the
// canonical Apple Human Interface Guidelines presentation for a
// self-contained data-entry task. Cancel + Save sit in the sheet's
// navigation bar; the sheet uses the `.large` detent on iPhone and
// auto-sizes as a form sheet on iPad / macOS.
//
// Phase 8 will add Duplicate / Parents / Rights / History buttons here.

import SwiftUI

/// Toolbar content with edit / add / delete actions for the entity detail view.
/// Edit and Add push `EntityEditView` onto the navigation stack via the
/// `editMode` binding; Delete fires the host's confirmation dialog.
private struct EntityToolbar: ToolbarContent {
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let entity: EntityDetail
    let menuId: String?
    @Binding var editMode: EntityEditMode?

    /// Placement for the Phase 8 placeholder buttons. On compact widths
    /// (iPhone) `.secondaryAction` collapses them into the system "..."
    /// overflow menu; on regular widths (iPad / macOS) we keep them
    /// inline alongside the primary actions to match the webapp toolbar.
    private var phase8Placement: ToolbarItemPlacement {
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
    /// as the list-column toolbar's Add. Surfaced here so the menu-level
    /// Add stays accessible while an entity is open in detail.
    private var menuLevelAddTypes: [AddFromType] {
        guard let menuId else { return [] }
        return menu.addFromTypes[menuId] ?? []
    }

    /// Types that can be added under this entity. Mirrors webapp's
    /// `addChildOptions`: prefer `addFromTypes[entity._id]` (skip when this
    /// entity is itself a meta-type — `entity` or `menu` — webapp's
    /// exclusion rule), fall back to `addFromTypes[entity.typeId]`. Empty
    /// means no add-child affordance is rendered.
    private var addChildTypes: [AddFromType] {
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

    var body: some ToolbarContent {
        // Mirrors the webapp's `entity/toolbar.vue` grouping (three
        // `n-button-group`s in the entity-actions area):
        //   1. Menu-level Add (standalone)
        //   2. Add child           (own group)
        //   3. Edit, Duplicate, Parents, Rights (one group)
        //   4. History             (own group)
        // `ToolbarSpacer(.fixed, ...)` (iOS 26 / macOS 26) inserts the
        // explicit gaps between groups so they don't auto-merge into a
        // single pill on macOS. Phase 6 implements Add child + Edit;
        // the rest render disabled until Phase 8.
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
        // Phase 8 placeholders — placement flips between `.primaryAction`
        // (iPad / macOS — inline) and `.secondaryAction` (iPhone — system
        // "..." overflow menu) based on horizontal size class.
        ToolbarItemGroup(placement: phase8Placement) {
            duplicateButton
            parentsButton
            rightsButton
            historyButton
        }
    }

    // MARK: - Buttons (returned as opaque `some View` so each ToolbarItem
    // contains exactly one item — empty `EmptyView` when not applicable).

    @ViewBuilder
    private var menuLevelAddButton: some View {
        // Creating a top-level entity in the active menu requires write
        // access — gate on the authenticated user. In public-database mode
        // `currentUserId` is nil and the API would reject the POST anyway,
        // so hide the affordance to match webapp's `entity/toolbar.vue`.
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

    // MARK: - Phase 8 placeholders
    //
    // The four buttons below mirror webapp's `entity/toolbar.vue` order
    // and rights checks. They're rendered but disabled until Phase 8
    // wires them up to their drawers / endpoints. Keeping them visible
    // matches the webapp's UI and gives a hint of upcoming features.

    @ViewBuilder
    private var duplicateButton: some View {
        if rights.owner {
            Button {
                // Phase 8 — POST /entity/{id}/duplicate
            } label: {
                Label("duplicate", systemImage: "doc.on.doc")
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private var parentsButton: some View {
        if rights.editor {
            Button {
                // Phase 8 — parents drawer
            } label: {
                Label("parents", systemImage: "arrow.triangle.branch")
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private var rightsButton: some View {
        if rights.owner {
            Button {
                // Phase 8 — rights drawer
            } label: {
                Label("rights", systemImage: "person.2")
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private var historyButton: some View {
        if rights.editor {
            Button {
                // Phase 8 — GET /entity/{id}/history
            } label: {
                Label("history", systemImage: "clock.arrow.circlepath")
            }
            .disabled(true)
        }
    }
}

/// Wrapper that owns the sheet/dialog state and applies it around the
/// entity detail view. `EntityDetailView` adds `.entityToolbarHost(...)`.
extension View {
    /// Attach edit/add/delete sheets and the destructive confirmation
    /// dialog. The `EntityToolbar` `ToolbarContent` reads the same bindings.
    func entityToolbarHost(
        entity: EntityDetail,
        menuId: String? = nil,
        onEdited: (() -> Void)? = nil,
        onCreated: ((String) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(EntityToolbarHost(
            entity: entity,
            menuId: menuId,
            onEdited: onEdited,
            onCreated: onCreated,
            onDelete: onDelete
        ))
    }
}

private struct EntityToolbarHost: ViewModifier {
    @Environment(APIClient.self) private var api

    let entity: EntityDetail
    let menuId: String?
    let onEdited: (() -> Void)?
    let onCreated: ((String) -> Void)?
    let onDelete: (() -> Void)?

    @State private var editMode: EntityEditMode?

    /// Tracks whether the current sheet session committed at least one
    /// change. Reflects out to the parent via `onEdited` / `onCreated`
    /// only when the sheet dismisses — calling them mid-session would
    /// trigger a refetch that drops the `entityToolbarHost` modifier
    /// (because the host's `if let entity { ... }` branch goes false
    /// during `isLoading`), which in turn dismisses the very sheet the
    /// user is still typing into. The local upsert response already
    /// updates the in-sheet `entity` cache, so the parent's read view
    /// can wait until close to refresh.
    @State private var pendingCreatedId: String?
    @State private var didEditExisting = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                EntityToolbar(entity: entity, menuId: menuId, editMode: $editMode)
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
                }
                .presentationDetents([.large])
            }
    }
}
