import Foundation
import Testing
@testable import JournalCore

@MainActor
@Suite("Soft delete")
struct SoftDeleteTests {
    @Test func softDeletedEntriesAreHiddenButKept() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "Gone soon")
        stores.entries.softDelete(entry)

        #expect(stores.entries.allEntries().isEmpty)
        #expect(stores.entries.count() == 0)
        #expect(stores.entries.daySummaries().isEmpty)
        // The tombstone is still there, for sync.
        #expect(stores.entries.entry(id: entry.id)?.deletedAt != nil)
    }

    @Test func softDeleteCascadesToAttachments() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        let attachment = stores.attachments.add(photo, to: entry)
        stores.entries.softDelete(entry)
        #expect(attachment.deletedAt != nil)
        #expect(stores.attachments.allMedia().isEmpty)
    }

    @Test func restoreBringsBackEntryAndAttachments() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "Back again")
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        let attachment = stores.attachments.add(photo, to: entry)
        stores.entries.softDelete(entry)
        stores.entries.restore(entry)
        #expect(entry.deletedAt == nil)
        #expect(attachment.deletedAt == nil)
        #expect(stores.entries.count() == 1)
    }

    @Test func removingAttachmentClearsCoverAndKeepsFile() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        let attachment = stores.attachments.add(photo, to: entry)
        stores.entries.setCover(entry, attachmentID: attachment.id)
        stores.attachments.remove(attachment)
        #expect(entry.liveAttachments.isEmpty)
        #expect(entry.coverAttachmentID == nil)
        // Files are only removed when the tombstone is purged.
        #expect(FileManager.default.fileExists(atPath: stores.media.originalURL(for: photo.reference).path))
    }

    @Test func purgeRemovesOldTombstonesOnly() async throws {
        let stores = try makeStores()
        let old = stores.entries.create()
        stores.entries.setTitle(old, "old")
        let recent = stores.entries.create()
        stores.entries.setTitle(recent, "recent")
        stores.entries.softDelete(old)
        stores.entries.softDelete(recent)
        old.deletedAt = .now.addingTimeInterval(-40 * 86_400)

        stores.entries.purgeTombstones(olderThan: .now.addingTimeInterval(-30 * 86_400))
        #expect(stores.entries.entry(id: old.id) == nil)
        #expect(stores.entries.entry(id: recent.id) != nil)
    }

    @Test func deletedTagsAreHidden() throws {
        let stores = try makeStores()
        let tag = stores.tags.create(name: "Work")
        let entry = stores.entries.create()
        stores.entries.setTags(entry, [tag])
        stores.tags.softDelete(tag)
        #expect(stores.tags.allTags().isEmpty)
        #expect(entry.liveTags.isEmpty)
    }
}
