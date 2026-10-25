import CoreGraphics
import Foundation
import ImageIO
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Reads capture date, location and size from photos (EXIF) and from video and audio files.
enum MediaMetadataReader {
    struct Metadata: Sendable {
        var pixelWidth: Int?
        var pixelHeight: Int?
        var duration: Double?
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?
    }

    static func imageMetadata(at url: URL) -> Metadata {
        var meta = Metadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return meta }

        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // EXIF orientations 5 to 8 are rotated 90°, so width and height swap on screen.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let rotated = (5...8).contains(orientation)
            meta.pixelWidth = rotated ? height : width
            meta.pixelHeight = rotated ? width : height
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            meta.capturedAt = parseEXIFDate(original, offset: offset)
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            meta.latitude = latRef.uppercased() == "S" ? -lat : lat
            meta.longitude = lonRef.uppercased() == "W" ? -lon : lon
        }
        return meta
    }

    /// Parses "2026:10:24 18:30:05" with an optional "+02:00" offset. Without an offset
    /// the time is taken as local time, which is what the camera recorded.
    static func parseEXIFDate(_ value: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: value + offset) { return date }
        }
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    static func avMetadata(at url: URL) async -> Metadata {
        var meta = Metadata()
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            meta.duration = duration.seconds
        }
        if let creation = try? await asset.load(.creationDate),
           let date = try? await creation.load(.dateValue) {
            meta.capturedAt = date
        }
        if let items = try? await asset.load(.commonMetadata) {
            let locations = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierLocation)
            if let first = locations.first, let text = try? await first.load(.stringValue),
               let coordinate = parseISO6709(text) {
                meta.latitude = coordinate.latitude
                meta.longitude = coordinate.longitude
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
            meta.pixelWidth = Int(abs(rect.width).rounded())
            meta.pixelHeight = Int(abs(rect.height).rounded())
        }
        #endif
        return meta
    }

    /// Parses an ISO 6709 location such as "+37.3317-122.0302+012.345/".
    static func parseISO6709(_ text: String) -> (latitude: Double, longitude: Double)? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
            } else {
                current.append(character)
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1])
    }
}
