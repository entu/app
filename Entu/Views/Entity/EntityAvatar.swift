import SwiftUI

/// Circular avatar — thumbnail image or colored letter fallback.
struct EntityAvatar: View {
    @Environment(APIClient.self) private var api

    let name: String
    let entityId: String
    var hasPhoto: Bool = false
    var size: CGFloat = 28

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                letterCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Decorative — the avatar always sits next to the entity's name
        // text, so VoiceOver reading it would only duplicate the row.
        .accessibilityHidden(true)
        .task(id: entityId) {
            image = nil
            guard hasPhoto,
                  let url = await api.entityThumbnailURL(entityId: entityId, size: 200) else { return }
            image = await loadImage(from: url)
        }
    }

    private var letterCircle: some View {
        Circle()
            .fill(avatarColor)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.white)
            }
    }

    /// Deterministic colour from `name` — same name always produces the same colour.
    private var avatarColor: Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[hash % colors.count]
    }
}
