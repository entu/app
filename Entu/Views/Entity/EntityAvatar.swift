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
                  let url = await api.entityThumbnailURL(entityId: entityId, size: 50) else { return }
            image = await loadImage(from: url)
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
