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
                    detailSkeleton
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
                    ContentUnavailableView {
                        Label("loadError", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                            .textSelection(.enabled)
                    } actions: {
                        Button("retry") {
                            Task { await model.load(entityId: entityId) }
                        }
                    }
                }
            } else {
                detailSkeleton
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model?.entity?._id)
        .task(id: entityId) {
            let m = model ?? EntityDetailModel(api: api)
            model = m
            await m.load(entityId: entityId)
        }
    }

    /// Redacted placeholder mirroring the detail layout (title + property
    /// rows) — shown while the entity loads so content resolves in place
    /// instead of flashing from a spinner.
    private var detailSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Entity name placeholder")
                    .font(.title)
                    .fontWeight(.bold)

                ForEach(0..<6, id: \.self) { index in
                    HStack(alignment: .top, spacing: 16) {
                        Text(verbatim: "label")
                            .font(.subheadline)
                            .frame(minWidth: 80, alignment: .trailing)
                        Text(verbatim: String(repeating: "value ", count: 2 + index % 4))
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
