import Foundation
import SwiftData

public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case photo, video, audio, file

    /// Photos and videos have thumbnails and can be a cover.
    public var isVisual: Bool { self == .photo || self == .video }
}

/// A media file that belongs to an entry. The file itself lives on disk
/// (see `MediaStorage`), named by `id`; this record only holds its metadata.
@Model
public final class Attachment {
    /// Also the file name on disk.
    public var id: UUID = UUID()
    public var entry: Entry? = nil
    /// Stored as a raw string so the schema stays simple for CloudKit. Use `kind`.
    public var kindRaw: String = AttachmentKind.photo.rawValue
    /// jpg, heic, mov, m4a, pdf...
    public var fileExtension: String = ""
    /// Shown for files and audio.
    public var originalFilename: String? = nil
    public var byteSize: Int64 = 0
    public var pixelWidth: Int? = nil
    public var pixelHeight: Int? = nil
    /// Seconds, for video and audio.
    public var duration: Double? = nil
    /// From EXIF or file metadata.
    public var capturedAt: Date? = nil
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    /// Order in the media strip.
    public var sortOrder: Int = 0
    /// Audio transcription (later phase).
    public var transcript: String? = nil
    /// SHA-256 of the file, for de-duplication and sync integrity.
    public var contentHash: String? = nil

    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now
    public var deletedAt: Date? = nil

    public init(id: UUID = UUID(), kind: AttachmentKind, fileExtension: String) {
        let now = Date.now
        self.id = id
        self.kindRaw = kind.rawValue
        self.fileExtension = fileExtension
        self.createdAt = now
        self.modifiedAt = now
    }
}

public extension Attachment {
    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    /// The date shown on attachment tiles: when it was captured, else when it was added.
    var displayDate: Date { capturedAt ?? entry?.entryDate ?? createdAt }

    /// A Sendable snapshot for passing to background work and views.
    var reference: MediaReference {
        MediaReference(id: id, kind: kind, fileExtension: fileExtension, originalFilename: originalFilename, duration: duration)
    }
}

/// Just enough about an attachment to find and show its files, safe to pass across actors.
public struct MediaReference: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: AttachmentKind
    public let fileExtension: String
    public let originalFilename: String?
    public let duration: Double?

    public init(id: UUID, kind: AttachmentKind, fileExtension: String, originalFilename: String? = nil, duration: Double? = nil) {
        self.id = id
        self.kind = kind
        self.fileExtension = fileExtension
        self.originalFilename = originalFilename
        self.duration = duration
    }
}
