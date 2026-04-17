// Scrollable content layout for the entity detail view.
// Shows entity name, parent breadcrumb, meta info (thumbnail, type, sharing),
// grouped properties, and child entities.
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

                // Compact (iPhone): meta info centered above properties
                if sizeClass == .compact {
                    VStack(spacing: 16) {
                        metaSidebar

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
                } else {
                    // Regular (macOS, iPad): name + properties left, meta sidebar right
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
            .padding(sizeClass == .compact ? 16 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Meta sidebar (thumbnail + type + sharing)

    @ViewBuilder
    private var metaSidebar: some View {
        VStack(spacing: 8) {
            // Thumbnail — only shown if available
            if let thumbnail = entity._thumbnail, let url = URL(string: thumbnail) {
                ThumbnailView(url: url, token: api.token)
            }

            // Type badge — tappable, navigates to the type entity
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

            // Sharing badge
            sharingBadge
        }
        .frame(width: 160)
    }

    @ViewBuilder
    private var sharingBadge: some View {
        switch entity.sharing {
        case "domain":
            Label(String(localized: "sharingDomain"), systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.yellow.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case "public":
            Label(String(localized: "sharingPublic"), systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        default:
            Label(String(localized: "sharingPrivate"), systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Parent breadcrumbs

    /// Renders the parent hierarchy as a horizontal chain of tappable links.
    private func parentBreadcrumbs(_ parents: [PropertyValue]) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.up")
                .font(.caption2)
                .foregroundStyle(.separator)
                .frame(width: 20)

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

            Image(systemName: "arrow.up")
                .font(.caption2)
                .foregroundStyle(.separator)
                .frame(width: 20)
        }
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
            ForEach(Array(group.properties.enumerated()), id: \.offset) { _, prop in
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

// Loads entity thumbnail with auth token, using the shared ImageLoader.
private struct ThumbnailView: View {
    let url: URL
    let token: String?

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.fill.quaternary)
                    .frame(height: 160)
            }
        }
        .frame(width: 160)
        .task {
            image = await loadImage(from: url, token: token)
        }
    }
}
