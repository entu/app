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

    /// Localized label of the entity's type — the raw type name fills in
    /// until it resolves.
    var typeLabel: String?

    /// Called when user taps a reference or child entity — navigates to it.
    var onNavigate: ((String) -> Void)?

    /// Measured width of the view. Used to fold to the compact layout when
    /// the column is narrower than the regular layout needs — e.g. macOS
    /// users dragging the detail column down to a narrow width.
    @State private var contentWidth: CGFloat = .infinity

    @State private var coverImage: Image?
    @State private var coverRGB: RGBColor?

    /// Below this width, fold to the tighter layout.
    private let compactThreshold: CGFloat = 500

    private var isCompact: Bool {
        sizeClass == .compact || contentWidth < compactThreshold
    }

    private var coverSize: CGFloat { isCompact ? 96 : 128 }
    private var edgePadding: CGFloat { isCompact ? 16 : 28 }
    // Compact includes the status bar + nav bar the band runs behind —
    // the title/cover must clear the toolbar buttons.
    private var bandHeight: CGFloat { isCompact ? 210 : 172 }
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
                    HStack(spacing: 6) {
                        parentChips
                        Spacer()
                        sharingChip
                    }
                    .padding(.leading, entity.hasPhoto ? coverSize + 20 : 0)
                    .padding(.top, 14)
                    // 20 + the first group's 20 + its row's 4 = the
                    // canonical 44pt section gap.
                    .padding(.bottom, 20)

                    ForEach(groupedProperties) { group in
                        propertyGroupSection(group)
                    }
                    .padding(.top, 20)

                    // Child entities — 40 + the last row's 4pt padding =
                    // the canonical 44pt section gap.
                    ChildEntitiesSection(entityId: entity._id, onNavigate: onNavigate)
                        .padding(.top, 40)
                }
                .padding(.horizontal, edgePadding)
                .padding(.bottom, 24)
            }
        }
        .background(Color("WindowBackground"))
        // The gradient band runs behind the (hidden-background) toolbar on
        // every platform — macOS window toolbar, iOS navigation bar.
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .task(id: entity._id) {
            coverImage = nil
            // Session cache first — the header paints its final color
            // immediately when the list avatar (or a previous visit)
            // already derived it.
            coverRGB = EntityColorCache.shared.colors[entity._id]
            guard entity.hasPhoto,
                  let url = await api.entityThumbnailURL(entityId: entity._id, size: 400),
                  let platformImage = await loadPlatformImage(from: url) else { return }
            coverImage = platformToImage(platformImage)

            if coverRGB == nil, let rgb = dominantRGB(of: platformImage) {
                EntityColorCache.shared.colors[entity._id] = rgb
                withAnimation(.easeInOut(duration: 0.3)) {
                    coverRGB = rgb
                }
            }
        }
    }

    // MARK: - Header band

    /// Clearance above the title so a wrapped (two-line) title can't grow
    /// up into the toolbar the band runs behind — the band stretches taller
    /// instead (content-driven height with `bandHeight` as the minimum).
    private var bandTopClearance: CGFloat { isCompact ? 112 : 64 }

    private var headerBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entity.displayName)
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                .lineLimit(2)
                .textSelection(.enabled)

            badgeChips
        }
        .padding(.leading, titleLeading)
        .padding(.trailing, edgePadding)
        .padding(.top, bandTopClearance)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, minHeight: bandHeight, alignment: .bottomLeading)
        .background(headerGradient)
        .overlay(alignment: .bottomLeading) {
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

        return coverHeaderGradient(rgb)
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

    /// Parent references as quiet pills below the band.
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
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(.fill.quaternary, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Type chip (glass pill on the gradient)

    @ViewBuilder
    private var badgeChips: some View {
        if let typeId = entity.typeId, let label = typeLabel ?? entity.typeName {
            Button {
                onNavigate?(typeId)
            } label: {
                Text(verbatim: label)
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

    // MARK: - Sharing chip (tinted pill below the band, trailing)

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
            .lineLimit(1)
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
            // Group header. Together with the per-group 20pt from the
            // ForEach in `body` and the previous row's 4pt padding this
            // makes the canonical 44pt section gap.
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
