import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import JournalCore

@MainActor
func makeStores() throws -> JournalStores {
    try JournalStores.inMemory()
}

/// Writes a small solid-color JPEG for media tests.
func writeTestJPEG(width: Int = 64, height: Int = 48) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return url
}
