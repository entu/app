// Entity detail container — owns loading / error states and data
// fetching, then hands the loaded entity to `EntityDetailContent`.

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

    /// Pops the drill-down history — non-nil while there is history to pop;
    /// rendered as the entity toolbar's first pill on macOS.
    var onBack: (() -> Void)?

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
                        typeLabel: model.typeLabel,
                        onNavigate: onNavigate
                    )
                    .refreshable { await model.load(entityId: entityId) }
                    .id(entity._id)
                    .transition(.opacity)
                    .entityToolbarHost(
                        entity: entity,
                        typeLabel: model.typeLabel,
                        menuId: menuId,
                        onBack: onBack,
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
                        onListChanged: { onListChanged?() },
                        onReload: {
                            Task { await model.reload(entityId: entityId) }
                            // ⌘R refreshes the surrounding list too.
                            onListChanged?()
                        }
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
        // Fill the pane before painting the background — states that don't
        // stretch on their own (the error view) would otherwise carry a
        // content-sized gray box.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("WindowBackground").ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: model?.entity?._id)
        .task(id: entityId) {
            let m = model ?? EntityDetailModel(api: api)
            model = m
            await m.load(entityId: entityId)
        }
    }

    /// Placeholder shown while the entity loads: only the colored header
    /// band (the entity's derived id color — the same one the loaded header
    /// starts from, so nothing jumps) over the plain window background.
    /// Title, cover, and rows appear together once the entity arrives.
    private var detailSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(skeletonGradient)
                    .frame(maxWidth: .infinity)
                    .frame(height: 172)
            }
        }
        .background(Color("WindowBackground"))
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        #if os(macOS)
        // Disabled toolbar stand-in — keeps the window toolbar layout
        // stable while the entity loads.
        .toolbar { EntityToolbarPlaceholder(onBack: onBack, menuId: menuId) }
        #endif
    }

    /// Cover-derived gradient when the session cache already knows this
    /// entity's color, the id-derived gradient otherwise — so the band shows
    /// its final color while loading whenever possible.
    private var skeletonGradient: LinearGradient {
        if let rgb = EntityColorCache.shared.colors[entityId] {
            return coverHeaderGradient(rgb)
        }

        return Color.derivedGradient(from: entityId)
    }
}
