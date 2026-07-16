// Avatar for the signed-in user. When a thumbnail URL is provided, fetches
// the image and renders it as a circle with a thin white border. With no
// thumbnail (or while loading), falls back to either the square Entu logo
// (account sheet hero) or a generic bordered person icon (sidebar pill) —
// the logo fallback is intentionally NOT clipped, bordered, or shadowed.

import SwiftUI

/// Fallback shown when the user has no thumbnail.
enum UserAvatarFallback {
    case logo
    case personIcon
}

/// User avatar — round thumbnail with white border, or a fallback.
struct UserAvatar: View {
    /// Signed thumbnail URL string for the user entity, or nil for the fallback.
    let thumbnail: String?

    /// Width and height in points. The border scales as `max(1, size / 32)`.
    let size: CGFloat

    var fallback: UserAvatarFallback = .logo

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(.white, lineWidth: max(1, size / 32))
                    }
            } else {
                switch fallback {
                case .logo:
                    Image("Logo").resizable().scaledToFit()
                        .frame(width: size, height: size)
                case .personIcon:
                    Circle()
                        .fill(.fill.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.5))
                                .foregroundStyle(.secondary)
                        }
                        .overlay {
                            Circle().strokeBorder(.separator, lineWidth: 1)
                        }
                        .frame(width: size, height: size)
                }
            }
        }
        // Reset the image first so a stale photo never bleeds across
        // database switches while the new fetch is in flight.
        .task(id: thumbnail) {
            image = nil
            guard let thumbnail, let url = URL(string: thumbnail) else { return }

            image = await loadImage(from: url)
        }
    }
}
