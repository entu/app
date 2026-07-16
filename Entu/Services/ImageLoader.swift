// Handles 303 redirects that `AsyncImage` can't follow, and caches
// loaded images in memory so scrolling back doesn't re-fetch.

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

    /// Drop every cached image — called on logout so a signed-out session
    /// keeps no thumbnails of the previous user's data in memory.
    func clear() {
        cache.removeAllObjects()
    }
}

/// Load an image from URL with optional Bearer token auth, caching the result.
func loadImage(from url: URL, token: String? = nil) async -> Image? {
    await loadPlatformImage(from: url, token: token).map(platformToImage)
}

/// Load the raw platform image (cached) — for callers that need pixel
/// access, e.g. deriving the entity header color from the cover average.
func loadPlatformImage(from url: URL, token: String? = nil) async -> PlatformImage? {
    if let cached = ImageCache.shared.get(url) {
        return cached
    }

    var request = URLRequest(url: url)
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let platformImage = PlatformImage(data: data) else { return nil }

    ImageCache.shared.set(platformImage, for: url)
    return platformImage
}

func platformToImage(_ image: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: image)
    #else
    Image(uiImage: image)
    #endif
}
