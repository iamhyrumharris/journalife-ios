import Foundation

/// A version of an entry that lost a sync conflict. Kept so no writing is ever silently lost.
public struct ConflictedCopy: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// When the conflict was found.
    public var savedAt: Date
    /// The version that lost.
    public var entry: EntryRecord

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Conflicted copies, stored as JSON files under `Sync/Conflicts/`.
///
// DECISION: the spec asks for a hidden "conflicted copy" entry. Copies are files rather than
// entries so they never show up on the calendar, never sync themselves, and need no schema
// change. Settings > Sync lists them, and one can be restored as a new entry.
public struct ConflictStore: Sendable {
    public let folder: URL

    public init(location: StorageLocation) {
        folder = location.conflictsURL
    }

    public func all() -> [ConflictedCopy] {
        let decoder = ArchiveFormat.makeDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ConflictedCopy.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public var count: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    func save(_ entry: EntryRecord) {
        let copy = ConflictedCopy(id: UUID(), savedAt: .now, entry: entry)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try ArchiveFormat.makeEncoder().encode(copy)
            try data.write(to: url(for: copy.id), options: FileProtection.writingOptions)
        } catch {
            logger.error("Couldn't save conflicted copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func delete(_ copy: ConflictedCopy) {
        try? FileManager.default.removeItem(at: url(for: copy.id))
    }

    private func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }
}

extension EntryStore {
    /// Turns a conflicted copy back into a normal entry (a new one, so it doesn't fight the
    /// version that won). Attachments aren't copied; the winning entry still has them.
    @discardableResult
    public func restore(_ copy: ConflictedCopy) -> Entry {
        let record = copy.entry
        let entry = create(date: record.entryDate, timeZone: TimeZone(identifier: record.timeZoneID) ?? .current)
        update(entry) {
            $0.title = record.title
            $0.bodyRich = try? (record.body ?? RichText(plain: record.bodyPlain)).encoded()
            $0.bodyPlain = record.bodyPlain
            $0.rating = record.rating
            $0.latitude = record.latitude
            $0.longitude = record.longitude
            $0.placeName = record.placeName
        }
        return entry
    }
}
