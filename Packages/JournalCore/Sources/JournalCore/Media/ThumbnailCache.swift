import CoreGraphics
import Foundation
import ImageIO

/// A decoded image that can cross actors. `CGImage` is immutable, so this is safe.
public struct DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
}

/// In-memory cache of decoded thumbnails, shared by every screen.
/// Cells only ever load the 256px previews, never full images.
public final class ThumbnailCache: @unchecked Sendable {
    // NSCache is thread-safe, which is what makes the @unchecked Sendable above sound.
    private let cache = NSCache<NSString, CGImage>()
    private let location: StorageLocation

    public init(location: StorageLocation, countLimit: Int = 600) {
        self.location = location
        cache.countLimit = countLimit
    }

    public func cachedImage(id: UUID, size: ThumbnailSize) -> DecodedImage? {
        cache.object(forKey: key(id, size)).map(DecodedImage.init)
    }

    /// Loads and decodes a thumbnail off the main actor, from the cache when possible.
    public func image(id: UUID, size: ThumbnailSize) async -> DecodedImage? {
        if let cached = cachedImage(id: id, size: size) { return cached }
        let url = location.thumbnailURL(id: id, size: size)
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(url)
        }.value
        if let decoded { cache.setObject(decoded.cgImage, forKey: key(id, size)) }
        return decoded
    }

    /// Drops cached images for an attachment, for example after its thumbnails are regenerated.
    public func evict(id: UUID) {
        for size in ThumbnailSize.allCases { cache.removeObject(forKey: key(id, size)) }
    }

    public func removeAll() { cache.removeAllObjects() }

    private func key(_ id: UUID, _ size: ThumbnailSize) -> NSString {
        "\(id.uuidString)_\(size.rawValue)" as NSString
    }

    private static func decode(_ url: URL) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return DecodedImage(cgImage: image)
    }
}
