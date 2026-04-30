// Rights-gated toolbar for `EntityDetailView`. Buttons hide when the
// active user lacks the required right (and entirely in public mode,
// where `currentUserId` is nil and every right is false).
//
// Edit and Add child open `EntityEditView` as a sheet — the sheet
// autosaves on blur and owns its own Delete button, so this toolbar has
// no Delete. Phase 8 placeholders render disabled and collapse into the
// system "..." menu on iPhone via `phase8Placement`.

import SwiftUI

/// Edit / Add buttons that open `EntityEditView` via the `editMode` binding,
/// plus disabled Phase 8 placeholders.
private struct EntityToolbar: ToolbarContent {
    @Environment(AuthModel.self) private var auth
    @Environment(MenuModel.self) private var menu
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let entity: EntityDetail
    let menuId: String?
    @Binding var editMode: EntityEditMode?

    /// Compact (iPhone) → `.secondaryAction` collapses into the "..." menu;
    /// regular (iPad / macOS) → `.primaryAction` keeps them inline.
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
    /// the list-column toolbar's Add uses, surfaced here too.
    private var menuLevelAddTypes: [AddFromType] {
        guard let menuId else { return [] }
        return menu.addFromTypes[menuId] ?? []
    }

    /// Types that can be added under this entity. Mirrors webapp's
    /// `addChildOptions`: prefer `addFromTypes[entity._id]`, skipping the
    /// `entity`/`menu` meta-types, then fall back to the type's allow-list.
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
        ToolbarItemGroup(placement: phase8Placement) {
            duplicateButton
            parentsButton
            rightsButton
            historyButton
        }
    }

    // MARK: - Buttons

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

    // MARK: - Phase 8 placeholders (rendered disabled until the drawers ship)

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

extension View {
    /// Attach the entity toolbar plus its edit/create sheet and confirmation
    /// dialogs. Used by `EntityDetailView`.
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

    /// Buffered until sheet dismiss: firing `onEdited`/`onCreated` mid-session
    /// would refetch the parent entity, drop the host modifier, and dismiss
    /// the sheet the user is still typing into.
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
