import Foundation
import Testing
@testable import JournalCore

/// A provider that keeps everything in memory, shared by two "devices" in a test.
actor MemoryRemote: SyncProvider {
    nonisolated let kind = SyncProviderKind.webDAV
    private var records: [String: (record: SyncRecord, sequence: Int)] = [:]
    private var sequence = 0
    private(set) var files: [UUID: Data] = [:]
    private(set) var pushCount = 0

    func prepare() async throws {}

    func pullChanges(since token: Data?) async throws -> SyncPage {
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = records.values.filter { $0.sequence > since }.map(\.record)
        return SyncPage(records: changed, token: Data(String(sequence).utf8))
    }

    func pushChanges(_ batch: [SyncRecord], token: Data?) async throws -> SyncPushResult {
        for record in batch {
            sequence += 1
            records[record.key] = (record, sequence)
            pushCount += 1
        }
        return SyncPushResult(saved: Set(batch.map(\.key)))
    }

    func uploadFile(_ file: SyncFile, from url: URL) async throws {
        files[file.id] = try Data(contentsOf: url)
    }

    func downloadFile(_ file: SyncFile, to url: URL) async throws -> Bool {
        guard let data = files[file.id] else { return false }
        try data.write(to: url)
        return true
    }

    func deleteFile(_ file: SyncFile) async throws {
        files[file.id] = nil
    }

    var recordCount: Int { records.count }
}

@MainActor
struct Device {
    let stores: JournalStores
    let engine: SyncEngine

    init(remote: MemoryRemote) throws {
        stores = try makeStores()
        engine = SyncEngine(provider: remote, stores: stores, stateName: "test")
        engine.installHooks()
    }

    @discardableResult
    func sync() async throws -> SyncReport { try await engine.sync() }

    func write(_ title: String, body: String = "") -> Entry {
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, title)
        if !body.isEmpty { stores.entries.setBody(entry, richText: RichText(plain: body)) }
        return entry
    }

    func entry(_ id: UUID) -> Entry? { stores.entries.entry(id: id) }
}

@MainActor
@Suite("Sync")
struct SyncTests {
    @Test func editOnOneDeviceShowsUpOnTheOther() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)

        let entry = phone.write("Hike", body: "Up the canyon")
        try await phone.sync()
        try await mac.sync()
        let copy = try #require(mac.entry(entry.id))
        #expect(copy.title == "Hike")
        #expect(copy.bodyPlain == "Up the canyon")

        mac.stores.entries.setTitle(copy, "Long hike")
        try await mac.sync()
        try await phone.sync()
        #expect(phone.entry(entry.id)?.title == "Long hike")
        #expect(phone.stores.entries.count() == 1)
    }

    @Test func deletesSync() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)
        let entry = phone.write("Delete me")
        try await phone.sync()
        try await mac.sync()
        #expect(mac.stores.entries.count() == 1)

        phone.stores.entries.softDelete(try #require(phone.entry(entry.id)))
        try await phone.sync()
        try await mac.sync()
        #expect(mac.stores.entries.count() == 0)
        #expect(mac.entry(entry.id)?.deletedAt != nil)
    }

    @Test func emptyDraftsDontSyncAndSyncedEntriesLeaveTombstones() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)

        let draft = phone.stores.entries.create()
        try await phone.sync()
        #expect(await remote.recordCount == 0)
        #expect(phone.stores.entries.discardIfEmpty(draft))
        #expect(phone.entry(draft.id) == nil)

        let entry = phone.write("Soon empty")
        try await phone.sync()
        try await mac.sync()
        phone.stores.entries.setTitle(entry, "")
        #expect(phone.stores.entries.discardIfEmpty(entry))
        // Synced before, so it's a tombstone, not a hard delete.
        #expect(phone.entry(entry.id)?.deletedAt != nil)
        try await phone.sync()
        try await mac.sync()
        #expect(mac.stores.entries.count() == 0)
    }

    @Test func hundredOfflineEditsOnBothSidesMakeNoDuplicates() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)
        let tag = phone.stores.tags.create(name: "Daily")
        var shared: [Entry] = []
        for index in 0..<10 {
            let entry = phone.write("Shared \(index)")
            phone.stores.entries.setTags(entry, [tag])
            shared.append(entry)
        }
        try await phone.sync()
        try await mac.sync()
        #expect(mac.stores.entries.count() == 10)

        // Offline: 100 edits on each side, new entries and edits to the shared ones.
        for index in 0..<50 { _ = phone.write("Phone \(index)") }
        for index in 0..<50 { _ = mac.write("Mac \(index)") }
        for (index, entry) in shared.enumerated() {
            for round in 0..<5 {
                if index.isMultiple(of: 2) {
                    phone.stores.entries.setBody(entry, richText: RichText(plain: "phone \(round)"))
                } else {
                    let macEntry = try #require(mac.entry(entry.id))
                    mac.stores.entries.setBody(macEntry, richText: RichText(plain: "mac \(round)"))
                }
            }
        }

        try await phone.sync()
        try await mac.sync()
        try await phone.sync()

        let phoneIDs = Set(phone.stores.entries.allEntries().map(\.id))
        let macIDs = Set(mac.stores.entries.allEntries().map(\.id))
        #expect(phoneIDs.count == 110)
        #expect(phoneIDs == macIDs)
        for id in phoneIDs {
            #expect(phone.entry(id)?.bodyPlain == mac.entry(id)?.bodyPlain)
            #expect(phone.entry(id)?.title == mac.entry(id)?.title)
        }
        #expect(phone.stores.tags.allTags().count == 1)
        #expect(mac.stores.tags.allTags().count == 1)
        #expect(mac.entry(shared[0].id)?.liveTags.map(\.name) == ["Daily"])
        // Nothing left to send.
        let report = try await phone.sync()
        #expect(report.pushed == 0)
    }

    @Test func mediaRoundTripsIntact() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)

        let entry = phone.write("Photo day")
        let photo = try await phone.stores.media.importFile(at: try writeTestJPEG(), move: true)
        phone.stores.attachments.add(photo, to: entry)
        try await phone.sync()
        let report = try await mac.sync()
        #expect(report.downloadedFiles == 1)

        let attachment = try #require(mac.entry(entry.id)?.liveAttachments.first)
        let url = mac.stores.media.originalURL(for: attachment.reference)
        #expect(try MediaStorage.sha256(of: url) == photo.contentHash)
        #expect(mac.stores.media.hasThumbnails(for: attachment.id))

        // Removing it on the Mac removes it on the phone.
        mac.stores.attachments.remove(attachment)
        try await mac.sync()
        try await phone.sync()
        #expect(phone.entry(entry.id)?.liveAttachments.isEmpty == true)
    }

    @Test func conflictingTextKeepsTheLosingCopy() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)
        let entry = phone.write("Draft", body: "first")
        try await phone.sync()
        try await mac.sync()

        phone.stores.entries.setBody(entry, richText: RichText(plain: "written on the phone"))
        try await Task.sleep(for: .milliseconds(20))
        let macEntry = try #require(mac.entry(entry.id))
        mac.stores.entries.setBody(macEntry, richText: RichText(plain: "written on the mac"))

        try await phone.sync()
        try await mac.sync()
        try await phone.sync()

        // The Mac edited last, so it wins everywhere, and the phone's text is kept as a copy.
        #expect(phone.entry(entry.id)?.bodyPlain == "written on the mac")
        #expect(mac.entry(entry.id)?.bodyPlain == "written on the mac")
        let copies = mac.engine.conflicts.all() + phone.engine.conflicts.all()
        #expect(copies.map(\.entry.bodyPlain) == ["written on the phone"])

        let restored = mac.stores.entries.restore(try #require(copies.first))
        #expect(restored.bodyPlain == "written on the phone")
        #expect(restored.id != entry.id)
    }

    @Test func sameTagCreatedOnBothDevicesMerges() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)
        let phoneEntry = phone.write("Phone")
        phone.stores.entries.setTags(phoneEntry, [phone.stores.tags.create(name: "Work")])
        let macEntry = mac.write("Mac")
        mac.stores.entries.setTags(macEntry, [mac.stores.tags.create(name: "work")])

        try await phone.sync()
        try await mac.sync()
        try await phone.sync()
        try await mac.sync()

        #expect(phone.stores.tags.allTags().count == 1)
        #expect(mac.stores.tags.allTags().map(\.id) == phone.stores.tags.allTags().map(\.id))
        let tagID = try #require(phone.stores.tags.allTags().first?.id)
        #expect(phone.entry(macEntry.id)?.liveTags.map(\.id) == [tagID])
        #expect(mac.entry(phoneEntry.id)?.liveTags.map(\.id) == [tagID])
    }

    @Test func remoteChangesWaitWhileTheEntryIsOpen() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let mac = try Device(remote: remote)
        let entry = phone.write("Open")
        try await phone.sync()
        try await mac.sync()

        mac.stores.entries.setTitle(try #require(mac.entry(entry.id)), "Changed on Mac")
        try await mac.sync()
        phone.engine.isEntryOpen = { $0 == entry.id }
        let report = try await phone.sync()
        #expect(report.deferred == 1)
        #expect(phone.entry(entry.id)?.title == "Open")

        phone.engine.isEntryOpen = { _ in false }
        try await phone.sync()
        #expect(phone.entry(entry.id)?.title == "Changed on Mac")
    }

    @Test func tombstonesWaitUntilSynced() async throws {
        let remote = MemoryRemote()
        let phone = try Device(remote: remote)
        let entry = phone.write("Old")
        try await phone.sync()
        phone.stores.entries.softDelete(entry)
        let later = Date.now.addingTimeInterval(31 * 86_400)
        await phone.stores.purgeDeletedItems(now: later)
        #expect(phone.entry(entry.id) != nil)
        try await phone.sync()
        await phone.stores.purgeDeletedItems(now: later)
        #expect(phone.entry(entry.id) == nil)
    }

    @Test func webDAVConfigurationNormalizesAddresses() throws {
        let config = try #require(WebDAVConfiguration(address: "nas.local:5006/journal", username: " me "))
        #expect(config.folderURL.absoluteString == "https://nas.local:5006/journal/")
        #expect(config.username == "me")
        #expect(WebDAVConfiguration(address: "ftp://x", username: "me") == nil)
        #expect(WebDAVConfiguration(address: "http://192.168.1.4/dav", username: "a")?.isInsecure == false)
        #expect(WebDAVConfiguration(address: "http://example.com/dav", username: "a")?.isInsecure == true)
    }

    @Test func webDAVKeysMapToPaths() {
        let id = UUID()
        #expect(WebDAVSyncProvider.path(forKey: SyncRecord.key(.entry, id)) == "entries/\(id.uuidString).json")
        #expect(WebDAVSyncProvider.path(forKey: SyncRecord.key(.tag, id)) == "tags/\(id.uuidString).json")
        #expect(WebDAVSyncProvider.kind(ofKey: SyncRecord.key(.tag, id)) == .tag)
    }
}
