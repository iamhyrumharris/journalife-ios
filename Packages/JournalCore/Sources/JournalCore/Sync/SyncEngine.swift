import Foundation
import SwiftData

/// What a sync did, for the status line and tests.
public struct SyncReport: Sendable, Equatable {
    public var pulled = 0
    public var applied = 0
    public var pushed = 0
    public var uploadedFiles = 0
    public var downloadedFiles = 0
    public var conflicts = 0
    /// Remote changes held back because their entry is open in the editor.
    public var deferred = 0

    public init() {}
}

/// Progress for the status line.
public enum SyncStep: Sendable, Equatable {
    case checking
    case downloadingChanges
    case uploadingFiles(done: Int, total: Int)
    case downloadingFiles(done: Int, total: Int)
    case uploadingChanges(done: Int, total: Int)
}

/// Runs one sync against a provider: pull and merge, then files, then push.
///
/// Merge rule (spec): last writer wins per record, by `modifiedAt`. When both sides changed an
/// entry's text since the last sync, the losing version is kept as a conflicted copy.
///
// DECISION: merging runs on the main context (not a background one). Merges are quick (ids and
// dates are compared first, and only changed records are decoded), and it means an open screen
// never holds a stale copy of a record sync just changed. Network and file work stays off the main actor.
@MainActor
public final class SyncEngine {
    public let provider: any SyncProvider
    private let stores: JournalStores
    private let stateURL: URL
    private(set) var state: SyncState
    public let conflicts: ConflictStore

    /// Entries open in the editor. Remote changes to them wait until the editor closes, so
    /// typing is never replaced under the cursor.
    public var isEntryOpen: (UUID) -> Bool = { _ in false }

    private var context: ModelContext { stores.context }

    /// - Parameter stateName: names this provider's state file (see `StorageLocation.syncStateURL`).
    public init(provider: any SyncProvider, stores: JournalStores, stateName: String) {
        self.provider = provider
        self.stores = stores
        self.stateURL = stores.location.syncStateURL(name: stateName)
        self.state = SyncState.load(from: stateURL)
        self.conflicts = ConflictStore(location: stores.location)
    }

    public var lastSyncAt: Date? { state.lastSyncAt }

    // MARK: Hooks for the stores

    /// Points the stores' delete guards at this engine's change log.
    public func installHooks() {
        stores.syncHooks.wasSynced = { [weak self] id in
            self?.state.syncedDate(SyncRecord.key(.entry, id)) != nil
        }
        stores.syncHooks.mayPurge = { [weak self] item in
            guard let self else { return true }
            return self.mayPurge(item)
        }
    }

    /// A tombstone can go once its record is synced (or never was) and the provider no longer
    /// holds its file.
    private func mayPurge(_ item: SyncHooks.Item) -> Bool {
        switch item {
        case .entry(let id, let modifiedAt):
            let key = SyncRecord.key(.entry, id)
            return state.syncedDate(key) == nil || state.isSynced(key, modifiedAt: modifiedAt)
        case .tag(let id, let modifiedAt):
            let key = SyncRecord.key(.tag, id)
            return state.syncedDate(key) == nil || state.isSynced(key, modifiedAt: modifiedAt)
        case .attachment(let id, let entryID, let entryModifiedAt):
            guard !state.uploadedFiles.contains(id) else { return false }
            guard let entryID, let entryModifiedAt else { return true }
            let key = SyncRecord.key(.entry, entryID)
            return state.syncedDate(key) == nil || state.isSynced(key, modifiedAt: entryModifiedAt)
        }
    }

    // MARK: Sync

    /// One full sync. `includeFiles` is false in background refresh while the phone is locked,
    /// since media files can't be read then.
    @discardableResult
    public func sync(includeFiles: Bool = true, progress: @MainActor (SyncStep) -> Void = { _ in }) async throws -> SyncReport {
        var report = SyncReport()
        progress(.checking)
        try await provider.prepare()

        // 1. Pull and merge.
        progress(.downloadingChanges)
        var incoming: [SyncRecord] = state.pending.compactMap { try? SyncRecord.decode(kind: $0.kind, payload: $0.payload) }
        var token = state.token
        while true {
            let page = try await provider.pullChanges(since: token)
            incoming.append(contentsOf: page.records)
            report.pulled += page.records.count
            token = page.token
            if !page.hasMore { break }
        }
        let deferred = apply(incoming, report: &report)
        state.token = token
        state.pending = deferred.map { .init(kind: $0.kind, payload: $0.payload) }
        report.deferred = deferred.count
        saveContext()
        try saveState()

        // 2. Files go up before the records that point at them, so another device never
        // pulls an entry whose photo isn't there yet.
        if includeFiles {
            try await syncFiles(report: &report, progress: progress)
        }

        // 3. Push local changes.
        let outgoing = localChanges()
        var sent = 0
        var firstFailure: (any Error)?
        for chunk in outgoing.chunked(into: 100) {
            progress(.uploadingChanges(done: sent, total: outgoing.count))
            let result = try await provider.pushChanges(Array(chunk), token: state.token)
            for record in chunk where result.saved.contains(record.key) {
                state.markSynced(record.key, record.modifiedAt)
            }
            if let newToken = result.token { state.token = newToken }
            sent += chunk.count
            report.pushed += result.saved.count
            try saveState()
            if let failure = result.failure, firstFailure == nil { firstFailure = failure }
        }
        if let firstFailure { throw firstFailure }

        state.lastSyncAt = .now
        try saveState()
        return report
    }

    private func saveContext() {
        do {
            if context.hasChanges { try context.save() }
        } catch {
            logger.error("Sync save failed: \(error.localizedDescription, privacy: .public)")
        }
        stores.changes.bump()
    }

    private func saveState() throws {
        try state.save(to: stateURL)
    }

    // MARK: Pull

    /// Applies remote records. Returns the ones that must wait (their entry is open).
    private func apply(_ incoming: [SyncRecord], report: inout SyncReport) -> [SyncRecord] {
        guard !incoming.isEmpty else { return [] }
        // Newest copy of each record only.
        var latest: [String: SyncRecord] = [:]
        for record in incoming {
            if let existing = latest[record.key], !SyncClock.newer(record.modifiedAt, than: existing.modifiedAt) { continue }
            latest[record.key] = record
        }
        let records = Array(latest.values)
        let decoder = ArchiveFormat.makeDecoder()

        var tagsByID: [UUID: Tag] = [:]
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { tagsByID[tag.id] = tag }

        // Tags first, so entries can link to them.
        var tagsChanged = false
        for record in records where record.kind == .tag {
            guard let remote = try? decoder.decode(TagRecord.self, from: record.payload) else { continue }
            if applyTag(remote, record: record, tagsByID: &tagsByID) {
                report.applied += 1
                tagsChanged = true
            }
        }

        let entryRecords = records.filter { $0.kind == .entry }
        var entriesByID: [UUID: Entry] = [:]
        var attachmentsByID: [UUID: Attachment] = [:]
        if !entryRecords.isEmpty {
            for entry in (try? context.fetch(FetchDescriptor<Entry>())) ?? [] { entriesByID[entry.id] = entry }
            for attachment in (try? context.fetch(FetchDescriptor<Attachment>())) ?? [] { attachmentsByID[attachment.id] = attachment }
        }

        var deferred: [SyncRecord] = []
        for record in entryRecords {
            let local = entriesByID[record.id]
            if let local, !SyncClock.same(local.modifiedAt, record.modifiedAt), isEntryOpen(local.id) {
                deferred.append(record)
                continue
            }
            guard let remote = try? decoder.decode(EntryRecord.self, from: record.payload) else { continue }
            switch applyEntry(remote, record: record, local: local, tagsByID: tagsByID, attachmentsByID: &attachmentsByID) {
            case .applied(let entry):
                entriesByID[entry.id] = entry
                report.applied += 1
            case .appliedWithConflict(let entry):
                entriesByID[entry.id] = entry
                report.applied += 1
                report.conflicts += 1
            case .keptLocal(let conflict):
                if conflict { report.conflicts += 1 }
            case .unchanged:
                break
            }
        }

        if tagsChanged { mergeDuplicateTags() }
        return deferred
    }

    /// Returns true when the local tag changed.
    private func applyTag(_ remote: TagRecord, record: SyncRecord, tagsByID: inout [UUID: Tag]) -> Bool {
        let key = record.key
        guard let local = tagsByID[remote.id] else {
            state.markSynced(key, record.modifiedAt)
            // A tombstone for a tag this device never had: nothing to do.
            guard remote.deletedAt == nil else { return false }
            let tag = Tag(id: remote.id, name: remote.name, colorHex: remote.colorHex, symbolName: remote.symbolName, sortOrder: remote.sortOrder)
            remote.apply(to: tag)
            tag.deletedAt = remote.deletedAt
            context.insert(tag)
            tagsByID[tag.id] = tag
            return true
        }
        if SyncClock.same(local.modifiedAt, remote.modifiedAt) {
            state.markSynced(key, local.modifiedAt)
            return false
        }
        guard SyncClock.newer(remote.modifiedAt, than: local.modifiedAt) else { return false } // Local wins; pushed later.
        remote.apply(to: local)
        local.deletedAt = remote.deletedAt
        state.markSynced(key, local.modifiedAt)
        return true
    }

    private enum EntryOutcome {
        case applied(Entry)
        case appliedWithConflict(Entry)
        case keptLocal(conflict: Bool)
        case unchanged
    }

    private func applyEntry(
        _ remote: EntryRecord,
        record: SyncRecord,
        local: Entry?,
        tagsByID: [UUID: Tag],
        attachmentsByID: inout [UUID: Attachment]
    ) -> EntryOutcome {
        let key = record.key
        let base = state.syncedDate(key)

        guard let local else {
            state.markSynced(key, record.modifiedAt)
            guard remote.deletedAt == nil else { return .unchanged }
            let entry = Entry(id: remote.id, entryDate: remote.entryDate)
            context.insert(entry)
            write(remote, to: entry, tagsByID: tagsByID, attachmentsByID: &attachmentsByID)
            return .applied(entry)
        }

        if SyncClock.same(local.modifiedAt, remote.modifiedAt) {
            state.markSynced(key, local.modifiedAt)
            return .unchanged
        }

        let localChanged = base.map { !SyncClock.same($0, local.modifiedAt) } ?? true
        let remoteChanged = base.map { !SyncClock.same($0, remote.modifiedAt) } ?? true
        let bothEdited = localChanged && remoteChanged && local.deletedAt == nil && remote.deletedAt == nil
            && (local.title != remote.title || local.bodyPlain != remote.bodyPlain)

        if SyncClock.newer(remote.modifiedAt, than: local.modifiedAt) {
            if bothEdited { conflicts.save(EntryRecord(syncing: local)) }
            write(remote, to: local, tagsByID: tagsByID, attachmentsByID: &attachmentsByID)
            state.markSynced(key, local.modifiedAt)
            return bothEdited ? .appliedWithConflict(local) : .applied(local)
        } else {
            // Local wins and is pushed later. Keep the remote text if it was a real edit.
            if bothEdited { conflicts.save(remote) }
            // Attachments the other device added still belong here, even though the rest of
            // the entry is older.
            mergeAttachments(remote.attachments, into: local, attachmentsByID: &attachmentsByID)
            return .keptLocal(conflict: bothEdited)
        }
    }

    private func write(_ remote: EntryRecord, to entry: Entry, tagsByID: [UUID: Tag], attachmentsByID: inout [UUID: Attachment]) {
        remote.apply(to: entry)
        entry.deletedAt = remote.deletedAt
        entry.tags = remote.tagIDs.compactMap { tagsByID[$0] }
        mergeAttachments(remote.attachments, into: entry, attachmentsByID: &attachmentsByID)
        // apply(to:) set modifiedAt from the record; keep it exactly so the change log matches.
        entry.modifiedAt = remote.modifiedAt
    }

    /// Per attachment, last writer wins too.
    private func mergeAttachments(_ records: [AttachmentRecord], into entry: Entry, attachmentsByID: inout [UUID: Attachment]) {
        for record in records {
            if let existing = attachmentsByID[record.id] {
                if SyncClock.newer(record.modifiedAt, than: existing.modifiedAt) {
                    record.apply(to: existing)
                    existing.deletedAt = record.deletedAt
                }
                if existing.entry?.id != entry.id { existing.entry = entry }
            } else {
                // Unknown and already deleted: nothing to keep.
                guard record.deletedAt == nil else { continue }
                let attachment = Attachment(id: record.id, kind: record.kind, fileExtension: record.fileExtension)
                record.apply(to: attachment)
                context.insert(attachment)
                attachment.entry = entry
                attachmentsByID[attachment.id] = attachment
            }
        }
    }

    /// Two devices can each create a tag with the same name. Both devices pick the same winner
    /// (the lower id), move entries onto it and delete the other, so they end up identical.
    private func mergeDuplicateTags() {
        let live = ((try? context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
        let groups = Dictionary(grouping: live) { SearchMatcher.fold($0.name) }
        let now = Date.now
        for (_, tags) in groups where tags.count > 1 {
            let sorted = tags.sorted { $0.id.uuidString < $1.id.uuidString }
            let winner = sorted[0]
            for loser in sorted.dropFirst() {
                for entry in loser.entries ?? [] {
                    var links = entry.tags ?? []
                    links.removeAll { $0.id == loser.id }
                    if !links.contains(where: { $0.id == winner.id }) { links.append(winner) }
                    entry.tags = links
                    entry.modifiedAt = now
                }
                loser.deletedAt = now
                loser.modifiedAt = now
            }
        }
    }

    // MARK: Push

    /// Records changed since they last matched the provider.
    private func localChanges() -> [SyncRecord] {
        let encoder = ArchiveFormat.makeEncoder()
        var result: [SyncRecord] = []

        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] {
            let key = SyncRecord.key(.tag, tag.id)
            if state.isSynced(key, modifiedAt: tag.modifiedAt) { continue }
            // Created and deleted before it ever synced: nobody needs to hear about it.
            if tag.deletedAt != nil, state.syncedDate(key) == nil { continue }
            guard let data = try? encoder.encode(TagRecord(syncing: tag)) else { continue }
            result.append(SyncRecord(kind: .tag, id: tag.id, modifiedAt: tag.modifiedAt, deletedAt: tag.deletedAt, payload: data))
        }

        for entry in (try? context.fetch(FetchDescriptor<Entry>())) ?? [] {
            let key = SyncRecord.key(.entry, entry.id)
            if state.isSynced(key, modifiedAt: entry.modifiedAt) { continue }
            if entry.deletedAt != nil, state.syncedDate(key) == nil { continue }
            // A new, still-empty entry is a draft that may be discarded; it syncs once it has content.
            if entry.deletedAt == nil, entry.isEmptyContent, entry.source == nil { continue }
            guard let data = try? encoder.encode(EntryRecord(syncing: entry)) else { continue }
            result.append(SyncRecord(kind: .entry, id: entry.id, modifiedAt: entry.modifiedAt, deletedAt: entry.deletedAt, payload: data))
        }
        return result
    }

    // MARK: Files

    private func syncFiles(report: inout SyncReport, progress: @MainActor (SyncStep) -> Void) async throws {
        let attachments = (try? context.fetch(FetchDescriptor<Attachment>())) ?? []
        let location = stores.location
        let fm = FileManager.default
        let purgeCutoff = Date.now.addingTimeInterval(-JournalStores.tombstoneLifetime)

        var uploads: [(SyncFile, URL)] = []
        var downloads: [(SyncFile, URL, MediaReference)] = []
        var removals: [SyncFile] = []
        for attachment in attachments {
            let file = SyncFile(id: attachment.id, fileExtension: attachment.fileExtension, byteSize: attachment.byteSize)
            let url = location.originalURL(id: attachment.id, fileExtension: attachment.fileExtension)
            let deletedAt = attachment.deletedAt ?? attachment.entry?.deletedAt
            if let deletedAt {
                // Remove the remote copy once the tombstone is old enough to purge.
                if deletedAt < purgeCutoff, state.uploadedFiles.contains(attachment.id) { removals.append(file) }
                continue
            }
            if fm.fileExists(atPath: url.path) {
                if !state.uploadedFiles.contains(attachment.id) { uploads.append((file, url)) }
            } else {
                downloads.append((file, url, attachment.reference))
            }
        }

        for (index, (file, url)) in uploads.enumerated() {
            progress(.uploadingFiles(done: index, total: uploads.count))
            try await provider.uploadFile(file, from: url)
            state.uploadedFiles.insert(file.id)
            report.uploadedFiles += 1
            if index % 20 == 19 { try saveState() }
        }

        var downloadedVisual = false
        for (index, (file, url, reference)) in downloads.enumerated() {
            progress(.downloadingFiles(done: index, total: downloads.count))
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try await provider.downloadFile(file, to: url) else { continue }
            FileProtection.apply(to: url)
            state.uploadedFiles.insert(file.id)
            report.downloadedFiles += 1
            if reference.kind.isVisual {
                await stores.media.generateThumbnails(for: reference)
                downloadedVisual = true
            }
            if index % 20 == 19 { try saveState() }
        }

        for file in removals {
            try await provider.deleteFile(file)
            state.uploadedFiles.remove(file.id)
        }
        try saveState()
        // New photos: let the calendar and lists pick up their thumbnails.
        if downloadedVisual { stores.changes.bump() }
    }
}

// MARK: Sync records

extension TagRecord {
    /// The sync form: like the archive, plus the tombstone.
    init(syncing tag: Tag) {
        self.init(tag)
        deletedAt = tag.deletedAt
    }
}

extension EntryRecord {
    /// The sync form: every attachment (tombstones too) and every linked tag, deleted or not,
    /// so a delete on one device reaches the others and a restored tag keeps its entries.
    init(syncing entry: Entry) {
        let attachments = (entry.attachments ?? [])
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            .map { attachment -> AttachmentRecord in
                var record = AttachmentRecord(attachment, file: nil)
                record.deletedAt = attachment.deletedAt
                return record
            }
        self.init(entry, attachments: attachments)
        tagIDs = (entry.tags ?? []).map(\.id)
        deletedAt = entry.deletedAt
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
