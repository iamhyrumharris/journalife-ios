import Foundation

/// The `.journalife` archive format, version 1. See docs/ARCHIVE_FORMAT.md.
///
/// A ZIP file containing:
/// - `manifest.json`: `ArchiveManifest`
/// - `tags.json`: `[TagRecord]`
/// - `entries.json`: `[EntryRecord]`, each with its attachments inline
/// - `Media/<first 2 chars of uuid>/<uuid>.<ext>`: original media files
///
/// The WebDAV sync format (Phase 3) reuses these JSON shapes.
public enum ArchiveFormat {
    public static let formatVersion = 1
    public static let fileExtension = "journalife"
    /// The extension older exports used. Apple's Journal app claims it on some devices, so new
    /// exports use `fileExtension`; files with this one can still be imported.
    public static let legacyFileExtension = "journalarchive"

    static let manifestPath = "manifest.json"
    static let tagsPath = "tags.json"
    static let entriesPath = "entries.json"

    static func mediaPath(id: UUID, fileExtension: String) -> String {
        let name = id.uuidString.lowercased()
        let file = fileExtension.isEmpty ? name : "\(name).\(fileExtension.lowercased())"
        return "Media/\(name.prefix(2))/\(file)"
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date \(text)")
        }
        return decoder
    }
}

public struct ArchiveManifest: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var entryCount: Int
    public var tagCount: Int
    public var attachmentCount: Int
}

public struct TagRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var symbolName: String
    public var sortOrder: Int
    public var createdAt: Date
    public var modifiedAt: Date
}

public struct AttachmentRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: AttachmentKind
    public var fileExtension: String
    public var originalFilename: String?
    public var byteSize: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var capturedAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var sortOrder: Int
    public var transcript: String?
    public var contentHash: String?
    public var createdAt: Date
    public var modifiedAt: Date
    /// Path of the file inside the archive, or nil if the file was missing at export.
    public var file: String?
}

public struct EntryRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var entryDate: Date
    public var timeZoneID: String
    public var title: String
    public var body: RichText?
    public var bodyPlain: String
    public var rating: Int?
    public var isFavorite: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var placeName: String?
    public var coverAttachmentID: UUID?
    public var tagIDs: [UUID]
    public var attachments: [AttachmentRecord]
    public var source: String?
    public var sourceID: String?
    public var createdAt: Date
    public var modifiedAt: Date
}

public struct ArchiveExportSummary: Sendable, Equatable {
    public var url: URL
    public var entryCount: Int
    public var attachmentCount: Int
    /// Attachments whose files were missing on disk, so only their metadata was exported.
    public var missingFiles: Int
}

public struct ArchiveImportSummary: Sendable, Equatable {
    public var entriesAdded = 0
    public var entriesUpdated = 0
    public var entriesUnchanged = 0
    public var tagsAdded = 0
    public var attachmentsAdded = 0
    public var filesRestored = 0

    public init() {}
}

public enum ArchiveError: Error, LocalizedError {
    case missingPart(String)
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .missingPart(let name): "The archive is missing \(name)."
        case .newerFormat(let version): "This archive was made by a newer version of the app (format \(version)). Update the app to import it."
        }
    }
}
