// Shared image loading utility with in-memory cache and auth support.
// Used by EntityAvatar (list thumbnails) and ThumbnailView (detail thumbnails).
//
// Handles 303 redirects that AsyncImage can't follow, and caches loaded
// images in memory so scrolling back doesn't re-fetch.

import SwiftUI

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Thread-safe in-memory image cache using NSCache.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    func get(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// Load an image from URL with optional Bearer token auth, caching the result.
func loadImage(from url: URL, token: String? = nil) async -> Image? {
    if let cached = ImageCache.shared.get(url) {
        return platformToImage(cached)
    }

    var request = URLRequest(url: url)
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let platformImage = PlatformImage(data: data) else { return nil }

    ImageCache.shared.set(platformImage, for: url)
    return platformToImage(platformImage)
}

private func platformToImage(_ image: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: image)
    #else
    Image(uiImage: image)
    #endif
}
