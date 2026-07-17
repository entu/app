// Entity-actions context menu shared by every row that represents an
// entity — list rows, child-table rows, and reference pills.

import SwiftUI

/// Context menu for any row representing an entity — the entity actions,
/// mirroring the toolbar (same icons and grouping). `select` makes the
/// entity the shown detail; the action itself rides
/// `DeepLinkRouter.pendingRowAction` and is consumed by `EntityToolbarHost`
/// once the entity is loaded, with the toolbar's rights gating.
struct EntityRowContextMenuItems: View {
    @Environment(DeepLinkRouter.self) private var router

    let entityId: String
    let select: () -> Void

    var body: some View {
        Button {
            trigger(.edit)
        } label: {
            Label("edit", systemImage: "pencil")
        }
        Button {
            trigger(.duplicate)
        } label: {
            Label("duplicate", systemImage: "doc.on.doc")
        }
        Button {
            trigger(.parents)
        } label: {
            Label("parents", systemImage: "arrow.up.folder")
        }

        Divider()

        Button {
            trigger(.rights)
        } label: {
            Label("rights", systemImage: "person.2")
        }
        Button {
            trigger(.history)
        } label: {
            Label("history", systemImage: "clock.arrow.circlepath")
        }
    }

    private func trigger(_ kind: DeepLinkRouter.PendingRowAction.Kind) {
        select()
        router.pendingRowAction = DeepLinkRouter.PendingRowAction(entityId: entityId, kind: kind)
    }
}

extension View {
    /// Attach the entity-actions context menu to a row for `entityId`.
    func entityRowContextMenu(entityId: String, select: @escaping () -> Void) -> some View {
        contextMenu {
            EntityRowContextMenuItems(entityId: entityId, select: select)
        }
    }
}
