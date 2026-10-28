import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Makes JPEG previews with ImageIO downsampling, so full images are never loaded into memory.
enum ThumbnailGenerator {
    enum ThumbnailError: Error { case unreadable, unwritable }

    static func makeImageThumbnail(from source: URL, to destination: URL, maxPixelSize: Int) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ThumbnailError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ThumbnailError.unreadable
        }
        try writeJPEG(image, to: destination)
    }

    static func makeVideoThumbnails(from source: URL, large: URL, small: URL) async throws {
        #if canImport(AVFoundation) && !os(watchOS)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(ThumbnailSize.large.rawValue)
        generator.maximumSize = CGSize(width: side, height: side)
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        try writeJPEG(image, to: large)
        try makeImageThumbnail(from: large, to: small, maxPixelSize: ThumbnailSize.small.rawValue)
        #else
        throw ThumbnailError.unreadable
        #endif
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.unwritable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.unwritable }
    }
}
