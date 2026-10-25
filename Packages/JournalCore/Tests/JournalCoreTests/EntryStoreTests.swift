import Foundation
import Testing
@testable import JournalCore

@MainActor
@Suite("EntryStore")
struct EntryStoreTests {
    @Test func createAndFetch() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "Hello")
        #expect(stores.entries.entry(id: entry.id)?.title == "Hello")
        #expect(stores.entries.count() == 1)
    }

    @Test func updateStampsModifiedAt() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        let before = entry.modifiedAt
        try await Task.sleep(for: .milliseconds(10))
        stores.entries.setRating(entry, 4)
        #expect(entry.modifiedAt > before)
        #expect(entry.rating == 4)
    }

    @Test func ratingIsClampedAndClearable() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setRating(entry, 9)
        #expect(entry.rating == 5)
        stores.entries.setRating(entry, nil)
        #expect(entry.rating == nil)
    }

    @Test func bodyKeepsPlainCopyInSync() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        let rich = RichText(runs: [.init(text: "Bold ", bold: true), .init(text: "plain")])
        stores.entries.setBody(entry, richText: rich)
        #expect(entry.bodyPlain == "Bold plain")
        #expect(entry.richText == rich)
    }

    @Test func newestFirstOrdering() throws {
        let stores = try makeStores()
        let old = stores.entries.create(date: .now.addingTimeInterval(-86_400 * 3))
        let new = stores.entries.create(date: .now)
        #expect(stores.entries.allEntries().map(\.id) == [new.id, old.id])
        #expect(stores.entries.allEntries(newestFirst: false).map(\.id) == [old.id, new.id])
    }

    @Test func entriesOnDayUseEntryTimeZone() throws {
        let stores = try makeStores()
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 23:30 on Oct 10 in Tokyo is still Oct 10 there, whatever the device time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23, minute: 30))!
        let entry = stores.entries.create(date: date, timeZone: tokyo)
        #expect(entry.dayKey == DayKey(year: 2026, month: 10, day: 10))
        #expect(stores.entries.entries(on: DayKey(year: 2026, month: 10, day: 10)).map(\.id) == [entry.id])
        #expect(stores.entries.entries(on: DayKey(year: 2026, month: 10, day: 11)).isEmpty)
    }

    @Test func adjacentEntries() throws {
        let stores = try makeStores()
        let a = stores.entries.create(date: .now.addingTimeInterval(-300))
        let b = stores.entries.create(date: .now.addingTimeInterval(-200))
        let c = stores.entries.create(date: .now.addingTimeInterval(-100))
        #expect(stores.entries.adjacent(to: b, direction: .previous)?.id == a.id)
        #expect(stores.entries.adjacent(to: b, direction: .next)?.id == c.id)
        #expect(stores.entries.adjacent(to: a, direction: .previous) == nil)
        #expect(stores.entries.adjacent(to: c, direction: .next) == nil)
    }

    @Test func discardIfEmptyRemovesOnlyEmptyEntries() throws {
        let stores = try makeStores()
        let empty = stores.entries.create()
        #expect(stores.entries.discardIfEmpty(empty))
        #expect(stores.entries.count() == 0)

        let written = stores.entries.create()
        stores.entries.setTitle(written, "Keep me")
        #expect(!stores.entries.discardIfEmpty(written))
        #expect(stores.entries.count() == 1)
    }

    @Test func duplicateCopiesTextAndTags() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "Original")
        let tag = stores.tags.create(name: "Travel")
        stores.entries.setTags(entry, [tag])
        let copy = stores.entries.duplicate(entry)
        #expect(copy.id != entry.id)
        #expect(copy.title == "Original")
        #expect(copy.liveTags.map(\.id) == [tag.id])
    }

    @Test func daySummariesCountAndCover() async throws {
        let stores = try makeStores()
        let day = DayKey.today
        let first = stores.entries.create(date: day.startDate().addingTimeInterval(3_600))
        let second = stores.entries.create(date: day.startDate().addingTimeInterval(7_200))
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        stores.attachments.add(photo, to: second)

        let summary = try #require(stores.entries.daySummaries()[day])
        #expect(summary.count == 2)
        #expect(summary.entryIDs == [first.id, second.id])
        #expect(summary.cover?.id == photo.id)
    }

    @Test func chosenCoverWins() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        let one = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        let two = try await stores.media.importFile(at: try writeTestJPEG(), move: true)
        stores.attachments.add(one, to: entry)
        stores.attachments.add(two, to: entry)
        #expect(stores.entries.daySummaries()[entry.dayKey]?.cover?.id == one.id)
        stores.entries.setCover(entry, attachmentID: two.id)
        #expect(stores.entries.daySummaries()[entry.dayKey]?.cover?.id == two.id)
    }

    @Test func changesBumpRevision() throws {
        let stores = try makeStores()
        let start = stores.changes.revision
        let entry = stores.entries.create()
        stores.entries.toggleFavorite(entry)
        #expect(stores.changes.revision > start)
        #expect(entry.isFavorite)
    }
}
