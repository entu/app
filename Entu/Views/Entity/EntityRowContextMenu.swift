// Entity-actions context menu shared by every row that represents an
// entity — list rows, child-table rows, and reference pills.

import SwiftUI

extension EnvironmentValues {
    /// Opens an entity in a new tab (macOS) / window (iPad) — set by
    /// `MainView` when the platform supports multiple windows, nil on
    /// iPhone (which hides the context-menu item).
    @Entry var openEntityInNewTab: ((String) -> Void)?
}

/// Context menu for any row representing an entity — open in new tab plus
/// the entity actions, mirroring the toolbar (same icons and grouping).
/// `select` makes the entity the shown detail; each action itself rides
/// `DeepLinkRouter.pendingRowAction` and is consumed by `EntityToolbarHost`
/// once the entity is loaded, with the toolbar's rights gating.
struct EntityRowContextMenuItems: View {
    @Environment(DeepLinkRouter.self) private var router
    @Environment(\.openEntityInNewTab) private var openEntityInNewTab

    let entityId: String
    let select: () -> Void

    var body: some View {
        if let openEntityInNewTab {
            Button {
                openEntityInNewTab(entityId)
            } label: {
                #if os(macOS)
                Label("openInNewTab", systemImage: "macwindow.badge.plus")
                #else
                Label("openInNewWindow", systemImage: "macwindow.badge.plus")
                #endif
            }

            Divider()
        }

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
