import SwiftUI

/// Container for entity detail — manages loading, error states, and data fetching.
struct EntityDetailView: View {
    @Environment(APIClient.self) private var api

    let entityId: String

    /// ID of the currently-selected menu entity. Drives the menu-level
    /// Add button in the entity toolbar so a top-level entity can be
    /// created without going back to the list column.
    var menuId: String?

    /// Called when user taps a reference or child entity — navigates to it.
    var onNavigate: ((String) -> Void)?

    /// Called after the entity is deleted — parent pops navigation.
    var onDelete: (() -> Void)?

    /// Called after a child / sibling list-affecting change (duplicate
    /// today; later: bulk operations) — parent refreshes the entity list.
    var onListChanged: (() -> Void)?

    @State private var model: EntityDetailModel?

    var body: some View {
        Group {
            if let model {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let entity = model.entity {
                    EntityDetailContent(
                        entity: entity,
                        groupedProperties: model.groupedProperties,
                        onNavigate: onNavigate
                    )
                    .refreshable { await model.load(entityId: entityId) }
                    .id(entity._id)
                    .transition(.opacity)
                    .entityToolbarHost(
                        entity: entity,
                        menuId: menuId,
                        onEdited: {
                            Task { await model.load(entityId: entityId) }
                            // Edited values can change the row's display name
                            // or thumbnail in the surrounding list.
                            onListChanged?()
                        },
                        onCreated: { newId in
                            onNavigate?(newId)
                            // New child appears in the parent's list view.
                            onListChanged?()
                        },
                        onDelete: {
                            EntityDetailModel.clearCache()
                            onDelete?()
                            // Deleted entity disappears from the list.
                            onListChanged?()
                        },
                        onListChanged: { onListChanged?() }
                    )
                } else if let message = model.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model?.entity?._id)
        .task(id: entityId) {
            let m = model ?? EntityDetailModel(api: api)
            model = m
            await m.load(entityId: entityId)
        }
    }
}
