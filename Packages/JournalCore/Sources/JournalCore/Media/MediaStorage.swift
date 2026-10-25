import CryptoKit
import Foundation

/// Copies media into the journal's folders, reads its metadata and makes thumbnails.
/// All file work happens here, off the main actor.
public actor MediaStorage {
    public nonisolated let location: StorageLocation

    public init(location: StorageLocation) {
        self.location = location
    }

    public enum MediaError: Error, LocalizedError {
        case missingSource(URL)

        public var errorDescription: String? {
            switch self {
            case .missingSource(let url): "The file \(url.lastPathComponent) could not be found."
            }
        }
    }

    public nonisolated func originalURL(for reference: MediaReference) -> URL {
        location.originalURL(id: reference.id, fileExtension: reference.fileExtension)
    }

    public nonisolated func thumbnailURL(id: UUID, size: ThumbnailSize) -> URL {
        location.thumbnailURL(id: id, size: size)
    }

    /// Copies (or moves) a file into `Media/`, reads its metadata and generates thumbnails.
    ///
    /// Photos keep their original format and quality (HEIC stays HEIC), so the app never
    /// depends on the photo still being in the user's library.
    public func importFile(
        at sourceURL: URL,
        kind: AttachmentKind? = nil,
        originalFilename: String? = nil,
        id: UUID = UUID(),
        move: Bool = false
    ) async throws -> ImportedMedia {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else { throw MediaError.missingSource(sourceURL) }
        let ext = sourceURL.pathExtension.lowercased()
        let kind = kind ?? AttachmentKind.infer(fromExtension: ext)
        let destination = location.originalURL(id: id, fileExtension: ext)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if move {
            try fm.moveItem(at: sourceURL, to: destination)
        } else {
            try fm.copyItem(at: sourceURL, to: destination)
        }
        FileProtection.apply(to: destination)

        var media = ImportedMedia(
            id: id,
            kind: kind,
            fileExtension: ext,
            originalFilename: originalFilename ?? sourceURL.lastPathComponent,
            byteSize: Self.fileSize(destination),
            contentHash: try? Self.sha256(of: destination)
        )
        switch kind {
        case .photo:
            let meta = MediaMetadataReader.imageMetadata(at: destination)
            media.pixelWidth = meta.pixelWidth
            media.pixelHeight = meta.pixelHeight
            media.capturedAt = meta.capturedAt
            media.latitude = meta.latitude
            media.longitude = meta.longitude
        case .video, .audio:
            let meta = await MediaMetadataReader.avMetadata(at: destination)
            media.pixelWidth = meta.pixelWidth
            media.pixelHeight = meta.pixelHeight
            media.duration = meta.duration
            media.capturedAt = meta.capturedAt
            media.latitude = meta.latitude
            media.longitude = meta.longitude
        case .file:
            break
        }
        await generateThumbnails(for: media.reference)
        return media
    }

    /// Writes in-memory data (for example a camera photo) as a new media file.
    public func importData(_ data: Data, fileExtension: String, kind: AttachmentKind? = nil, originalFilename: String? = nil) async throws -> ImportedMedia {
        let temp = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(fileExtension)")
        try data.write(to: temp, options: .atomic)
        return try await importFile(at: temp, kind: kind, originalFilename: originalFilename, move: true)
    }

    /// Makes the 256px and 1024px JPEG previews. Safe to call again to regenerate them.
    public func generateThumbnails(for reference: MediaReference) async {
        guard reference.kind.isVisual else { return }
        let original = location.originalURL(id: reference.id, fileExtension: reference.fileExtension)
        do {
            try FileManager.default.createDirectory(at: location.thumbsURL, withIntermediateDirectories: true)
            switch reference.kind {
            case .photo:
                for size in ThumbnailSize.allCases {
                    try ThumbnailGenerator.makeImageThumbnail(from: original, to: location.thumbnailURL(id: reference.id, size: size), maxPixelSize: size.rawValue)
                }
            case .video:
                try await ThumbnailGenerator.makeVideoThumbnails(
                    from: original,
                    large: location.thumbnailURL(id: reference.id, size: .large),
                    small: location.thumbnailURL(id: reference.id, size: .small)
                )
            case .audio, .file:
                break
            }
        } catch {
            logger.error("Thumbnail failed for \(reference.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when both thumbnails exist.
    public nonisolated func hasThumbnails(for id: UUID) -> Bool {
        ThumbnailSize.allCases.allSatisfy { FileManager.default.fileExists(atPath: location.thumbnailURL(id: id, size: $0).path) }
    }

    /// Deletes an attachment's original and thumbnails. Only call when purging a tombstone.
    public func removeFiles(for reference: MediaReference) {
        let fm = FileManager.default
        try? fm.removeItem(at: location.originalURL(id: reference.id, fileExtension: reference.fileExtension))
        for size in ThumbnailSize.allCases {
            try? fm.removeItem(at: location.thumbnailURL(id: reference.id, size: size))
        }
    }

    /// Bytes used by originals and thumbnails.
    public func storageUsed() -> (media: Int64, thumbnails: Int64) {
        (Self.folderSize(location.mediaURL), Self.folderSize(location.thumbsURL))
    }

    // MARK: Helpers

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// SHA-256 of a file, read in chunks so large videos don't load into memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
