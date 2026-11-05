import Foundation

/// What this device knows about one provider, saved as JSON under `Sync/` in the journal folder.
///
/// The change log: `records` holds, for every record, the `modifiedAt` it had when it last
/// matched the provider. A local record whose `modifiedAt` differs has changed since and is sent
/// on the next sync. That avoids SwiftData history tracking and survives app updates.
struct SyncState: Codable, Sendable {
    static let currentVersion = 1

    var version = SyncState.currentVersion
    /// The provider's opaque pull token.
    var token: Data?
    /// `SyncRecord.key` → `modifiedAt` (seconds since 1970) at the last sync.
    var records: [String: Double] = [:]
    /// Attachments whose files the provider holds.
    var uploadedFiles: Set<UUID> = []
    /// Remote changes that couldn't be applied yet (their entry was open in the editor).
    var pending: [PendingRecord] = []
    var lastSyncAt: Date?

    struct PendingRecord: Codable, Sendable {
        var kind: SyncRecordKind
        var payload: Data
    }

    func syncedDate(_ key: String) -> Date? {
        records[key].map { Date(timeIntervalSince1970: $0) }
    }

    mutating func markSynced(_ key: String, _ date: Date) {
        records[key] = date.timeIntervalSince1970
    }

    /// True when the record's current version matches what the provider has.
    func isSynced(_ key: String, modifiedAt: Date) -> Bool {
        guard let synced = syncedDate(key) else { return false }
        return SyncClock.same(synced, modifiedAt)
    }

    // MARK: Storage

    static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data),
              state.version <= currentVersion else { return SyncState() }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // DECISION: the state file is readable after first unlock (not complete protection), so
        // background refresh can sync while the phone is locked. It holds ids and dates, no text.
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(watchOS) || os(visionOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(self).write(to: url, options: options)
    }
}

extension StorageLocation {
    /// Sync state and conflicted copies.
    public var syncURL: URL { rootURL.appending(path: "Sync", directoryHint: .isDirectory) }

    /// The state file for one provider. Each provider (and each WebDAV folder) has its own,
    /// so switching starts a full upload to the new one.
    func syncStateURL(name: String) -> URL {
        syncURL.appending(path: "state-\(name).json")
    }

    public var conflictsURL: URL { syncURL.appending(path: "Conflicts", directoryHint: .isDirectory) }
}
