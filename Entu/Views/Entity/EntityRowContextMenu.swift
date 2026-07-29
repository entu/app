// Entity-actions context menu shared by every row that represents an
// entity — list rows, child-table rows, and reference pills.

import SwiftUI

/// Environment action that opens an entity's auxiliary window
/// (`EntityWindowRootView`). Always equal — closures aren't Equatable, and
/// a bare closure in the environment would read as "changed" on every
/// `MainView` render, invalidating every reader (see `ClearCacheCommand`
/// for the pattern).
struct OpenEntityInNewWindowAction: Equatable {
    let invoke: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Opens an entity's auxiliary window — set by
    /// `MainView`; nil outside it (which hides the context-menu item).
    @Entry var openEntityInNewWindow: OpenEntityInNewWindowAction?
}

/// Context menu for any row representing an entity — open in new window plus
/// the entity actions, mirroring the toolbar (same icons and grouping).
/// `select` makes the entity the shown detail; each action itself rides
/// `DeepLinkRouter.pendingRowAction` and is consumed by `EntityToolbarHost`
/// once the entity is loaded, with the toolbar's rights gating.
struct EntityRowContextMenuItems: View {
    @Environment(DeepLinkRouter.self) private var router
    @Environment(\.openEntityInNewWindow) private var openEntityInNewWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    let entityId: String
    let select: () -> Void

    var body: some View {
        // Hidden on iPhone (`supportsMultipleWindows` is false there).
        if supportsMultipleWindows, let openEntityInNewWindow {
            Button {
                openEntityInNewWindow.invoke(entityId)
            } label: {
                Label("openInNewWindow", systemImage: "macwindow.badge.plus")
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
