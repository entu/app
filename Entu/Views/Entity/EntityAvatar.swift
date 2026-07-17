// Entity identity tile — thumbnail when the entity has a photo,
// otherwise its initial on the id-derived gradient, so an entity keeps
// one color everywhere.

import SwiftUI

/// Rounded identity tile — thumbnail image or a letter on the entity's
/// derived gradient (hash of the id, so an entity keeps its color
/// everywhere: list, tables, search results).
struct EntityAvatar: View {
    @Environment(APIClient.self) private var api

    let name: String
    let entityId: String
    var hasPhoto: Bool = false
    var size: CGFloat = 24

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                letterTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4))
        // Decorative — the avatar always sits next to the entity's name
        // text, so VoiceOver reading it would only duplicate the row.
        .accessibilityHidden(true)
        .task(id: entityId) {
            image = nil
            // Small avatars (list + table) — the 50px thumbnail is plenty.
            guard hasPhoto,
                  let url = await api.entityThumbnailURL(entityId: entityId, size: 50),
                  let platformImage = await loadPlatformImage(from: url) else { return }
            image = platformToImage(platformImage)

            // Seed the session color cache from the thumbnail, so the
            // selection tint and the detail header know the entity's cover
            // color before the entity is ever opened.
            if EntityColorCache.shared.colors[entityId] == nil,
               let rgb = dominantRGB(of: platformImage) {
                EntityColorCache.shared.colors[entityId] = rgb
            }
        }
    }

    private var letterTile: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Color.derivedGradient(from: entityId))
            .overlay {
                Text(verbatim: String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}
