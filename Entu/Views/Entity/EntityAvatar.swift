// Circular avatar used in list rows — shows a thumbnail image if available,
// otherwise falls back to a colored circle with the first letter of the name.
// The color is deterministic (same name always gets the same color).

import SwiftUI

/// Circular avatar — thumbnail image or colored letter fallback.
struct EntityAvatar: View {
    @Environment(APIClient.self) private var api

    let name: String
    let thumbnail: String?

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                letterCircle
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .task(id: thumbnail) {
            guard let thumbnail, let url = URL(string: thumbnail) else { return }
            image = await loadImage(from: url, token: api.token)
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

    // Pick a consistent color from name — same name always produces the same color.
    private var avatarColor: Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[hash % colors.count]
    }
}
