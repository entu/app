// Container view for entity detail — manages loading state and data fetching.
// Displays a loading spinner, error message, or the entity content.
// Uses .task(id:) to refetch when a different entity is selected.

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
                        onEdited: { Task { await model.load(entityId: entityId) } },
                        onCreated: { newId in onNavigate?(newId) },
                        onDelete: {
                            EntityDetailModel.clearCache()
                            onDelete?()
                        }
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
