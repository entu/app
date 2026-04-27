// Scrollable content layout for the entity detail view.
// Shows entity name, parent breadcrumb, meta info (thumbnail, type, sharing),
// grouped properties, and child entities.
//
// Responsive: in a regular-width column, properties sit on the left and the
// thumbnail/type/sharing meta sits in a sidebar on the right. Below the
// `compactThreshold` width (or in a compact size class), the layout folds to
// a single stack — thumbnail and title up top, properties in the middle, type
// and sharing badges below the properties, then child entities.
//
// Pure presentation — receives all data from the parent view.

import SwiftUI

/// Scrollable entity detail layout — name, parents, properties, meta sidebar, children.
struct EntityDetailContent: View {
    @Environment(APIClient.self) private var api
    @Environment(\.horizontalSizeClass) private var sizeClass

    let entity: EntityDetail
    let groupedProperties: [PropertyGroup]

    // Called when user taps a reference or child entity — navigates to it.
    var onNavigate: ((String) -> Void)?

    /// Measured width of the view. Used to fold to the compact layout when
    /// the column is narrower than the regular two-column layout needs —
    /// e.g. macOS users dragging the detail column down to a narrow width.
    @State private var contentWidth: CGFloat = .infinity

    /// Below this width, fold to the iPhone-style stacked layout.
    private let compactThreshold: CGFloat = 500

    private var isCompact: Bool {
        sizeClass == .compact || contentWidth < compactThreshold
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Parent breadcrumb
                if let parents = entity.parents, !parents.isEmpty {
                    parentBreadcrumbs(parents)
                        .padding(.bottom, 16)
                    Divider()
                        .padding(.bottom, 16)
                }

                // Compact (iPhone or narrow macOS column): thumbnail + title at top,
                // properties, then type and sharing badges below the properties.
                if isCompact {
                    VStack(spacing: 16) {
                        thumbnailView

                        Text(entity.displayName)
                            .font(.title)
                            .fontWeight(.bold)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 24)

                    ForEach(groupedProperties) { group in
                        propertyGroupSection(group)
                    }

                    VStack(spacing: 8) {
                        typeBadge
                        sharingBadge
                    }
                    .frame(maxWidth: 240)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
                } else {
                    // Regular (wide macOS, iPad): name + properties left, meta sidebar right
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entity.displayName)
                                .font(.title)
                                .fontWeight(.bold)
                                .textSelection(.enabled)
                                .padding(.bottom, 24)

                            ForEach(groupedProperties) { group in
                                propertyGroupSection(group)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        metaSidebar
                    }
                }

                // Child entities
                ChildEntitiesSection(entityId: entity._id, onNavigate: onNavigate)
                    .padding(.top, 24)
            }
            .padding(isCompact ? 16 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }

    // MARK: - Meta sidebar (thumbnail + type + sharing) — used in regular layout

    @ViewBuilder
    private var metaSidebar: some View {
        VStack(spacing: 8) {
            thumbnailView
            typeBadge
            sharingBadge
        }
        .frame(width: 160)
    }

    /// Thumbnail image, when the entity has one.
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = entity._thumbnail, let url = URL(string: thumbnail) {
            ThumbnailView(url: url, token: api.token)
        }
    }

    /// Tappable type badge — navigates to the type entity.
    @ViewBuilder
    private var typeBadge: some View {
        if let typeName = entity.typeName, let typeId = entity.typeId {
            Button {
                onNavigate?(typeId)
            } label: {
                Text(typeName)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var sharingBadge: some View {
        switch entity.sharing {
        case "domain":
            sharingLabel("sharingDomain", systemImage: "person.2", color: .yellow)
        case "public":
            sharingLabel("sharingPublic", systemImage: "globe", color: .orange)
        default:
            sharingLabel("sharingPrivate", systemImage: "lock", color: .green)
        }
    }

    /// Caption-sized rounded badge — used by `sharingBadge` for each variant.
    private func sharingLabel(_ key: LocalizedStringResource, systemImage: String, color: Color) -> some View {
        Label(key, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Parent breadcrumbs

    /// Renders the parent hierarchy as a horizontal chain of tappable links.
    private func parentBreadcrumbs(_ parents: [PropertyValue]) -> some View {
        HStack(spacing: 0) {
            breadcrumbArrow

            ForEach(Array(parents.enumerated()), id: \.offset) { index, parent in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(.separator)
                }

                if let ref = parent.reference {
                    Button {
                        onNavigate?(ref)
                    } label: {
                        Text(parent.string ?? ref)
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }

            breadcrumbArrow
        }
    }

    /// Up-arrow icon used at both ends of the breadcrumb row.
    private var breadcrumbArrow: some View {
        Image(systemName: "arrow.up")
            .font(.caption2)
            .foregroundStyle(.separator)
            .frame(width: 20)
    }

    // MARK: - Property group section

    /// Renders a property group — optional group header followed by a row per property.
    private func propertyGroupSection(_ group: PropertyGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            if let name = group.name {
                Text(name.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
            }

            // Property rows
            ForEach(group.properties, id: \.definition.name) { prop in
                PropertyRow(
                    definition: prop.definition,
                    values: prop.values,
                    onNavigate: onNavigate
                )

                Divider()
            }
        }
    }
}

// MARK: - Thumbnail image view

// Square 160pt thumbnail loaded with the auth token.
private struct ThumbnailView: View {
    let url: URL
    let token: String?

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.fill.quaternary)
            }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.gray.opacity(0.3), lineWidth: 1)
        }
        .task {
            image = await loadImage(from: url, token: token)
        }
    }
}
