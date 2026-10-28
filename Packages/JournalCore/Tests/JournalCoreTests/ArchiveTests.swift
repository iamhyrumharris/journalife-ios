import Foundation
import Testing
@testable import JournalCore

@MainActor
@Suite("Archive")
struct ArchiveTests {
    private func makeJournal() async throws -> JournalStores {
        let stores = try makeStores()
        let travel = stores.tags.create(name: "Travel", colorHex: "#32D74B", symbolName: "airplane")
        let entry = stores.entries.create(date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "America/Denver")!)
        stores.entries.setTitle(entry, "Zion")
        stores.entries.setBody(entry, richText: RichText(runs: [.init(text: "Angels ", bold: true), .init(text: "Landing", italic: true)]))
        stores.entries.setRating(entry, 5)
        stores.entries.setLocation(entry, latitude: 37.27, longitude: -112.95, placeName: "Zion National Park")
        stores.entries.setTags(entry, [travel])
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        stores.attachments.add(photo, to: entry)
        stores.entries.setCover(entry, attachmentID: photo.id)

        let plain = stores.entries.create()
        stores.entries.setTitle(plain, "No media")
        return stores
    }

    @Test func exportThenImportRoundTrip() async throws {
        let source = try await makeJournal()
        let archiveURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).journalarchive")
        let summary = try await ArchiveService(modelContainer: source.container).export(to: archiveURL, location: source.location, appVersion: "test")
        #expect(summary.entryCount == 2)
        #expect(summary.attachmentCount == 1)
        #expect(summary.missingFiles == 0)

        let target = try makeStores()
        let result = try await ArchiveService(modelContainer: target.container).importArchive(from: archiveURL, location: target.location)
        target.reloadAfterBackgroundChanges()
        #expect(result.entriesAdded == 2)
        #expect(result.tagsAdded == 1)
        #expect(result.attachmentsAdded == 1)
        #expect(result.filesRestored == 1)

        let original = try #require(source.entries.allEntries().first { $0.title == "Zion" })
        let restored = try #require(target.entries.entry(id: original.id))
        #expect(restored.title == original.title)
        #expect(restored.richText == original.richText)
        #expect(restored.bodyPlain == "Angels Landing")
        #expect(restored.rating == 5)
        #expect(restored.placeName == "Zion National Park")
        #expect(restored.timeZoneID == "America/Denver")
        #expect(abs(restored.entryDate.timeIntervalSince(original.entryDate)) < 0.001)
        #expect(abs(restored.modifiedAt.timeIntervalSince(original.modifiedAt)) < 0.001)
        #expect(restored.liveTags.map(\.name) == ["Travel"])
        #expect(restored.liveTags.first?.symbolName == "airplane")
        #expect(restored.coverAttachmentID == original.coverAttachmentID)

        let attachment = try #require(restored.liveAttachments.first)
        let originalAttachment = try #require(original.liveAttachments.first)
        #expect(attachment.id == originalAttachment.id)
        #expect(attachment.contentHash == originalAttachment.contentHash)
        let restoredFile = target.media.originalURL(for: attachment.reference)
        #expect(try MediaStorage.sha256(of: restoredFile) == originalAttachment.contentHash)
        #expect(target.media.hasThumbnails(for: attachment.id))
    }

    @Test func importingTwiceDoesNotDuplicate() async throws {
        let source = try await makeJournal()
        let archiveURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).journalarchive")
        _ = try await ArchiveService(modelContainer: source.container).export(to: archiveURL, location: source.location)

        let target = try makeStores()
        let service = ArchiveService(modelContainer: target.container)
        _ = try await service.importArchive(from: archiveURL, location: target.location)
        let second = try await service.importArchive(from: archiveURL, location: target.location)
        #expect(second.entriesAdded == 0)
        #expect(second.entriesUnchanged == 2)
        #expect(second.tagsAdded == 0)
        #expect(target.entries.count() == 2)
        #expect(target.tags.allTags().count == 1)
        #expect(target.attachments.allMedia().count == 1)
    }

    @Test func newerLocalEditsWin() async throws {
        let source = try await makeJournal()
        let archiveURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).journalarchive")
        _ = try await ArchiveService(modelContainer: source.container).export(to: archiveURL, location: source.location)

        // Edit after exporting, then import the older archive into the same journal.
        let entry = try #require(source.entries.allEntries().first { $0.title == "Zion" })
        try await Task.sleep(for: .milliseconds(20))
        source.entries.setTitle(entry, "Zion (edited)")
        let result = try await ArchiveService(modelContainer: source.container).importArchive(from: archiveURL, location: source.location)
        source.reloadAfterBackgroundChanges()
        #expect(result.entriesUpdated == 0)
        #expect(source.entries.entry(id: entry.id)?.title == "Zion (edited)")
    }

    @Test func sameTagNameMergesIntoLocalTag() async throws {
        let source = try await makeJournal()
        let archiveURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).journalarchive")
        _ = try await ArchiveService(modelContainer: source.container).export(to: archiveURL, location: source.location)

        let target = try makeStores()
        let local = target.tags.create(name: "travel")
        _ = try await ArchiveService(modelContainer: target.container).importArchive(from: archiveURL, location: target.location)
        target.reloadAfterBackgroundChanges()
        #expect(target.tags.allTags().map(\.id) == [local.id])
        #expect(target.entries.allEntries().first { $0.title == "Zion" }?.liveTags.map(\.id) == [local.id])
    }

    @Test func rejectsNewerFormat() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).journalarchive")
        let writer = try ZipWriter(url: url)
        let manifest = ArchiveManifest(formatVersion: 99, exportedAt: .now, appVersion: nil, entryCount: 0, tagCount: 0, attachmentCount: 0)
        try writer.addData(try ArchiveFormat.makeEncoder().encode(manifest), path: "manifest.json")
        try writer.finish()

        let stores = try makeStores()
        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService(modelContainer: stores.container).importArchive(from: url, location: stores.location)
        }
    }
}
