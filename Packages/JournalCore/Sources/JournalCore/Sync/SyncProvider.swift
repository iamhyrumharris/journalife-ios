import Foundation

/// Which sync service is in use. Only one is active at a time.
public enum SyncProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case iCloud
    case webDAV

    public var id: String { rawValue }
}

/// The kinds of record that sync. Attachments travel inside their entry's record.
public enum SyncRecordKind: String, Codable, Sendable, CaseIterable {
    case tag
    case entry
}

/// One record as it travels to and from a provider: an `EntryRecord` or `TagRecord` as JSON
/// (the same shapes as the archive, plus `deletedAt`), with the fields the engine needs to merge.
public struct SyncRecord: Sendable, Equatable {
    public var kind: SyncRecordKind
    public var id: UUID
    public var modifiedAt: Date
    public var deletedAt: Date?
    /// The JSON of the `EntryRecord` or `TagRecord`.
    public var payload: Data

    public init(kind: SyncRecordKind, id: UUID, modifiedAt: Date, deletedAt: Date?, payload: Data) {
        self.kind = kind
        self.id = id
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.payload = payload
    }

    /// A stable name for the record, for example `entry.6F1C…`. Used as the CloudKit record name
    /// and in the WebDAV manifest.
    public var key: String { Self.key(kind, id) }

    public static func key(_ kind: SyncRecordKind, _ id: UUID) -> String {
        "\(kind.rawValue).\(id.uuidString)"
    }

    /// Reads the id and dates out of a record's JSON, for providers that store only the JSON.
    public static func decode(kind: SyncRecordKind, payload: Data) throws -> SyncRecord {
        let header = try ArchiveFormat.makeDecoder().decode(Header.self, from: payload)
        return SyncRecord(kind: kind, id: header.id, modifiedAt: header.modifiedAt, deletedAt: header.deletedAt, payload: payload)
    }

    private struct Header: Decodable {
        var id: UUID
        var modifiedAt: Date
        var deletedAt: Date?
    }
}

/// A media file that syncs alongside the records: an attachment's original.
public struct SyncFile: Sendable, Hashable {
    public var id: UUID
    public var fileExtension: String
    public var byteSize: Int64

    public init(id: UUID, fileExtension: String, byteSize: Int64) {
        self.id = id
        self.fileExtension = fileExtension
        self.byteSize = byteSize
    }

    /// `<first 2 chars of uuid>/<uuid>.<ext>`, the same layout as on disk.
    public var relativePath: String {
        let name = id.uuidString.lowercased()
        let file = fileExtension.isEmpty ? name : "\(name).\(fileExtension.lowercased())"
        return "\(name.prefix(2))/\(file)"
    }
}

/// What a pull returns: records changed since the token, and the token to pass next time.
public struct SyncPage: Sendable {
    public var records: [SyncRecord]
    /// Opaque to the engine. Saved after the page is applied.
    public var token: Data?
    /// True when the provider has more changes to hand out; pull again with `token`.
    public var hasMore: Bool

    public init(records: [SyncRecord], token: Data?, hasMore: Bool = false) {
        self.records = records
        self.token = token
        self.hasMore = hasMore
    }
}

/// What a push returns. Providers send what they can and report the rest, so one bad record
/// doesn't hold back the others.
public struct SyncPushResult: Sendable {
    /// Keys (`SyncRecord.key`) of the records the provider now holds.
    public var saved: Set<String>
    /// A new pull token that already counts these records as seen, so they aren't downloaded
    /// again on the next pull. Nil keeps the current token.
    public var token: Data?
    /// The first error, if some records weren't sent.
    public var failure: (any Error)?

    public init(saved: Set<String>, token: Data? = nil, failure: (any Error)? = nil) {
        self.saved = saved
        self.token = token
        self.failure = failure
    }
}

/// A place the journal syncs to (iCloud or a WebDAV folder). The engine (`SyncEngine`) owns
/// change tracking and merging; a provider only stores and hands back records and files.
public protocol SyncProvider: Sendable {
    var kind: SyncProviderKind { get }

    /// Checks the account or server and creates whatever the provider needs (a zone, folders).
    func prepare() async throws

    /// Records changed since `token` (all records when nil).
    func pullChanges(since token: Data?) async throws -> SyncPage

    /// Saves records, replacing older copies. `token` is the current pull token.
    func pushChanges(_ records: [SyncRecord], token: Data?) async throws -> SyncPushResult

    /// Uploads a media file, skipping it when the provider already has it.
    func uploadFile(_ file: SyncFile, from url: URL) async throws

    /// Downloads a media file to `url`. Returns false when the provider doesn't have it (yet).
    func downloadFile(_ file: SyncFile, to url: URL) async throws -> Bool

    /// Removes a media file whose attachment was deleted.
    func deleteFile(_ file: SyncFile) async throws
}

public enum SyncError: Error, LocalizedError, Equatable {
    case iCloudAccountUnavailable(String)
    case iCloudNotEnabled
    case invalidServerURL
    case authenticationFailed
    case server(status: Int, path: String)
    case notAWebDAVFolder
    case newerFormat(Int)
    case missingCredentials

    public var errorDescription: String? {
        switch self {
        case .iCloudAccountUnavailable(let reason): reason
        case .iCloudNotEnabled: String(localized: "iCloud sync isn't available in this build of the app.")
        case .invalidServerURL: String(localized: "The server address isn't a valid http or https URL.")
        case .authenticationFailed: String(localized: "The server didn't accept the user name and password.")
        case .server(let status, let path): String(localized: "The server returned error \(status) for \(path).")
        case .notAWebDAVFolder: String(localized: "That address isn't a WebDAV folder.")
        case .newerFormat(let version): String(localized: "This sync folder was written by a newer version of the app (format \(version)). Update the app to sync.")
        case .missingCredentials: String(localized: "The WebDAV password is missing. Enter it again in Settings > Sync.")
        }
    }
}

/// Compares sync timestamps. Records travel as JSON with millisecond precision, so two dates
/// within a millisecond are the same version.
enum SyncClock {
    static let tolerance: TimeInterval = 0.0015

    static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < tolerance }

    static func newer(_ a: Date, than b: Date) -> Bool { a.timeIntervalSince(b) >= tolerance }
}

/// Lets the sync layer guard deletes in the stores without the stores knowing about providers.
@MainActor
public final class SyncHooks {
    public enum Item {
        case entry(UUID, modifiedAt: Date)
        case tag(UUID, modifiedAt: Date)
        /// An attachment, with its entry when the entry itself isn't being purged.
        case attachment(UUID, entryID: UUID?, entryModifiedAt: Date?)
    }

    /// True when the entry has been sent to the sync provider, so deleting it must leave a tombstone.
    public var wasSynced: (UUID) -> Bool = { _ in false }

    /// True when a tombstone can be removed for good: other devices have heard about the delete
    /// and the provider no longer holds its file.
    public var mayPurge: (Item) -> Bool = { _ in true }

    public init() {}

    /// Back to no sync.
    public func reset() {
        wasSynced = { _ in false }
        mayPurge = { _ in true }
    }
}
