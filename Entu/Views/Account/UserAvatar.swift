// Avatar for the signed-in user. When a thumbnail URL is provided, fetches
// the image and renders it as a circle with a thin white border. With no
// thumbnail (or while loading), falls back to the square Entu logo — the
// fallback is intentionally NOT clipped or bordered.

import SwiftUI

/// User avatar — round thumbnail with white border, or Entu logo fallback.
struct UserAvatar: View {
    @Environment(APIClient.self) private var api

    /// URL string for the user entity's `_thumbnail`, or nil to show the logo.
    let thumbnail: String?

    /// Width and height in points. The border scales as `max(1, size / 32)`.
    let size: CGFloat

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
                Image("Logo").resizable().scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        // Reset the image first so a stale photo never bleeds across
        // database switches while the new fetch is in flight.
        .task(id: thumbnail) {
            image = nil
            guard let thumbnail, let url = URL(string: thumbnail) else { return }

            image = await loadImage(from: url, token: api.token)
        }
    }
}
