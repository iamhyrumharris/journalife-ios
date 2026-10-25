import Foundation
import UniformTypeIdentifiers

/// The result of copying a file into the journal: everything an `Attachment` needs.
public struct ImportedMedia: Sendable, Hashable {
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
    public var contentHash: String?

    public var reference: MediaReference {
        MediaReference(id: id, kind: kind, fileExtension: fileExtension, originalFilename: originalFilename, duration: duration)
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

public extension AttachmentKind {
    /// Guesses the kind from a file extension.
    static func infer(fromExtension ext: String) -> AttachmentKind {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return .file }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }
}
