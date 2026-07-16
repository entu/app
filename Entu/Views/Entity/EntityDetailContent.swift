// Scrollable content layout for the entity detail view.
// Cover header band: gradient derived from the cover thumbnail's dominant
// color (derived id color while it loads / when there is no image), white
// title and glass parent chips on the band, the square cover hanging over
// its bottom edge. Below: type + sharing chips, kicker-headed property
// groups, and the child-tables card.
//
// Responsive: below `compactThreshold` width (or in a compact size class)
// the band and cover shrink and paddings tighten.
//
// Pure presentation — receives all data from the parent view.

import SwiftUI

/// Scrollable entity detail layout — cover header, properties, children.
struct EntityDetailContent: View {
    @Environment(APIClient.self) private var api
    @Environment(\.horizontalSizeClass) private var sizeClass

    let entity: EntityDetail
    let groupedProperties: [PropertyGroup]

    /// Called when user taps a reference or child entity — navigates to it.
    var onNavigate: ((String) -> Void)?

    /// Measured width of the view. Used to fold to the compact layout when
    /// the column is narrower than the regular layout needs — e.g. macOS
    /// users dragging the detail column down to a narrow width.
    @State private var contentWidth: CGFloat = .infinity

    @State private var coverImage: Image?
    @State private var coverRGB: (red: Double, green: Double, blue: Double)?

    /// Below this width, fold to the tighter layout.
    private let compactThreshold: CGFloat = 500

    private var isCompact: Bool {
        sizeClass == .compact || contentWidth < compactThreshold
    }

    private var coverSize: CGFloat { isCompact ? 96 : 128 }
    private var edgePadding: CGFloat { isCompact ? 16 : 28 }
    private var bandHeight: CGFloat { isCompact ? 140 : 172 }
    /// How far the cover hangs below the header band.
    private var coverOverlap: CGFloat { coverSize / 3 }
    /// Leading inset of the title/chips block — clears the cover.
    private var titleLeading: CGFloat {
        entity.hasPhoto ? edgePadding + coverSize + 20 : edgePadding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBand
                    .zIndex(1)

                VStack(alignment: .leading, spacing: 0) {
                    badgeChips
                        .padding(.leading, entity.hasPhoto ? coverSize + 20 : 0)
                        .padding(.top, 14)

                    ForEach(groupedProperties) { group in
                        propertyGroupSection(group)
                    }
                    .padding(.top, 20)

                    // Child entities
                    ChildEntitiesSection(entityId: entity._id, onNavigate: onNavigate)
                        .padding(.top, 24)
                }
                .padding(.horizontal, edgePadding)
                .padding(.bottom, 24)
            }
        }
        .background(Color("WindowBackground"))
        #if os(macOS)
        // The gradient band runs behind the floating window toolbar.
        .ignoresSafeArea(edges: .top)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .task(id: entity._id) {
            coverImage = nil
            coverRGB = nil
            guard entity.hasPhoto,
                  let url = await api.entityThumbnailURL(entityId: entity._id, size: 400),
                  let platformImage = await loadPlatformImage(from: url) else { return }
            coverImage = platformToImage(platformImage)
            withAnimation(.easeInOut(duration: 0.3)) {
                coverRGB = dominantRGB(of: platformImage)
            }
        }
    }

    // MARK: - Header band

    private var headerBand: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(headerGradient)
                .frame(maxWidth: .infinity)
                .frame(height: bandHeight)

            VStack(alignment: .leading, spacing: 8) {
                Text(entity.displayName)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                    .lineLimit(2)
                    .textSelection(.enabled)

                parentChips
            }
            .padding(.leading, titleLeading)
            .padding(.trailing, edgePadding)
            .padding(.bottom, 14)

            if entity.hasPhoto {
                cover
                    .padding(.leading, edgePadding)
                    .offset(y: coverOverlap)
            }
        }
    }

    /// Header gradient — cover dominant color darkened toward the leading
    /// stop; the entity's derived id color while the cover loads or when
    /// there is no image (so an entity keeps its color everywhere).
    private var headerGradient: LinearGradient {
        guard let rgb = coverRGB else {
            return Color.derivedGradient(from: entity._id)
        }

        return LinearGradient(
            colors: [
                Color(red: rgb.red * 0.55, green: rgb.green * 0.55, blue: rgb.blue * 0.55),
                Color(red: min(rgb.red * 1.2, 1), green: min(rgb.green * 1.2, 1), blue: min(rgb.blue * 1.2, 1))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Square cover hanging over the band's bottom edge.
    private var cover: some View {
        Group {
            if let coverImage {
                coverImage.resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.2))
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }

    /// Parent references as glass pills on the gradient.
    @ViewBuilder
    private var parentChips: some View {
        let parents = (entity.parents ?? []).filter { $0.reference != nil }

        if !parents.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(parents.enumerated()), id: \.offset) { _, parent in
                    if let ref = parent.reference {
                        Button {
                            onNavigate?(ref)
                        } label: {
                            Label {
                                Text(parent.string ?? ref)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "arrow.up.folder")
                            }
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Type + sharing chips (below the band)

    private var badgeChips: some View {
        HStack(spacing: 6) {
            if let typeName = entity.typeName, let typeId = entity.typeId {
                Button {
                    onNavigate?(typeId)
                } label: {
                    Text(typeName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(.fill.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            sharingChip
        }
    }

    @ViewBuilder
    private var sharingChip: some View {
        switch entity.sharing {
        case "domain":
            sharingLabel("sharingDomain", systemImage: "person.2.fill", color: .yellow, textColor: Color("WarningText"))
        case "public":
            sharingLabel("sharingPublic", systemImage: "globe", color: .orange, textColor: Color("WarningText"))
        default:
            sharingLabel("sharingPrivate", systemImage: "lock.fill", color: .green, textColor: Color("SuccessText"))
        }
    }

    /// Tinted pill — used by `sharingChip` for each variant.
    private func sharingLabel(
        _ key: LocalizedStringResource,
        systemImage: String,
        color: Color,
        textColor: Color
    ) -> some View {
        Label(key, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(textColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: - Property group section

    /// Renders a property group — optional kicker header followed by a row
    /// per property.
    private func propertyGroupSection(_ group: PropertyGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            if let name = group.name {
                Text(name)
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 20)
                    .padding(.bottom, 6)
            }

            // Property rows — hairline between rows, none after the last.
            ForEach(group.properties, id: \.definition.name) { prop in
                PropertyRow(
                    definition: prop.definition,
                    values: prop.values,
                    onNavigate: onNavigate
                )

                if prop.definition.name != group.properties.last?.definition.name {
                    Divider()
                }
            }
        }
    }
}
