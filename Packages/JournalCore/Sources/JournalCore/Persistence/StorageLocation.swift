import Foundation
import os

let logger = Logger(subsystem: "JournalCore", category: "storage")

/// Where the database and media files live on disk.
///
/// Layout under `rootURL`:
/// - `Database/Journal.store` (SwiftData)
/// - `Media/<first 2 chars of uuid>/<uuid>.<ext>` (originals)
/// - `Thumbs/<uuid>_256.jpg` and `Thumbs/<uuid>_1024.jpg` (previews, excluded from device backup)
public struct StorageLocation: Sendable, Hashable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The shared App Group container, so widgets and the Watch extension can read it later.
    /// Falls back to Application Support when the App Group is not provisioned yet
    /// (for example before a bundle ID and team are set), so the app still runs.
    public static func appGroup(_ identifier: String?) -> StorageLocation {
        if let identifier, !identifier.isEmpty,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return StorageLocation(rootURL: url.appending(path: "Journal", directoryHint: .isDirectory))
        }
        logger.warning("App Group container unavailable for \(identifier ?? "nil", privacy: .public); using Application Support")
        let support = URL.applicationSupportDirectory.appending(path: "Journal", directoryHint: .isDirectory)
        return StorageLocation(rootURL: support)
    }

    /// A fresh folder in the temporary directory, for tests and previews.
    public static func temporary() -> StorageLocation {
        StorageLocation(rootURL: URL.temporaryDirectory.appending(path: "Journal-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    public var databaseURL: URL { rootURL.appending(path: "Database/Journal.store") }
    public var mediaURL: URL { rootURL.appending(path: "Media", directoryHint: .isDirectory) }
    public var thumbsURL: URL { rootURL.appending(path: "Thumbs", directoryHint: .isDirectory) }

    public func originalURL(id: UUID, fileExtension: String) -> URL {
        let name = id.uuidString.lowercased()
        let folder = String(name.prefix(2))
        let file = fileExtension.isEmpty ? name : "\(name).\(fileExtension.lowercased())"
        return mediaURL.appending(path: folder, directoryHint: .isDirectory).appending(path: file)
    }

    public func thumbnailURL(id: UUID, size: ThumbnailSize) -> URL {
        thumbsURL.appending(path: "\(id.uuidString.lowercased())_\(size.rawValue).jpg")
    }

    /// Creates the folders and marks `Thumbs/` as excluded from device backup (it can be regenerated).
    public func prepareDirectories() throws {
        let fm = FileManager.default
        for url in [rootURL, databaseURL.deletingLastPathComponent(), mediaURL, thumbsURL] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var thumbs = thumbsURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try thumbs.setResourceValues(values)
    }
}

public enum ThumbnailSize: Int, Sendable, CaseIterable {
    case small = 256
    case large = 1024
}

enum FileProtection {
    /// Applies complete file protection where the platform supports it.
    // DECISION: NSFileProtectionComplete for media, as the spec asks. If background sync
    // (Phase 3) needs to read files while locked, switch to completeUntilFirstUserAuthentication.
    static func apply(to url: URL) {
        #if os(iOS) || os(watchOS) || os(visionOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    static var writingOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}
