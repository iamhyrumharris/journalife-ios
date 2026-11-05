import Foundation
import Testing
@testable import JournalCore

@Suite("On This Day")
struct OnThisDayTests {
    @Test func sameDateInEarlierYearsOnly() {
        let today = DayKey(year: 2026, month: 10, day: 28)
        #expect(OnThisDay.matches(DayKey(year: 2025, month: 10, day: 28), on: today))
        #expect(OnThisDay.matches(DayKey(year: 2019, month: 10, day: 28), on: today))
        #expect(!OnThisDay.matches(DayKey(year: 2026, month: 10, day: 28), on: today))
        #expect(!OnThisDay.matches(DayKey(year: 2025, month: 10, day: 27), on: today))
        #expect(!OnThisDay.matches(DayKey(year: 2025, month: 9, day: 28), on: today))
    }

    @Test func leapDayShowsOnFebruary28InOtherYears() {
        let leapDay = DayKey(year: 2024, month: 2, day: 29)
        #expect(OnThisDay.matches(leapDay, on: DayKey(year: 2026, month: 2, day: 28)))
        #expect(!OnThisDay.matches(leapDay, on: DayKey(year: 2026, month: 3, day: 1)))
        // In a leap year, Feb 29 has its own day.
        #expect(!OnThisDay.matches(leapDay, on: DayKey(year: 2028, month: 2, day: 28)))
        #expect(OnThisDay.matches(leapDay, on: DayKey(year: 2028, month: 2, day: 29)))
    }

    @MainActor
    @Test func storeReturnsPastYearsNewestFirst() throws {
        let stores = try makeStores()
        let calendar = Calendar(identifier: .gregorian)
        func entry(_ year: Int, _ month: Int, _ day: Int, title: String) -> Entry {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            let entry = stores.entries.create(date: date)
            stores.entries.setTitle(entry, title)
            return entry
        }
        let older = entry(2020, 10, 28, title: "Older")
        let newer = entry(2024, 10, 28, title: "Newer")
        _ = entry(2026, 10, 28, title: "This year")
        _ = entry(2024, 10, 29, title: "Other day")
        let empty = stores.entries.create(date: calendar.date(from: DateComponents(year: 2023, month: 10, day: 28, hour: 9))!)
        let found = stores.entries.entriesOnThisDay(DayKey(year: 2026, month: 10, day: 28))
        #expect(found.map(\.id) == [newer.id, older.id])
        #expect(!found.contains { $0.id == empty.id })
    }
}

@Suite("Reminder plan")
struct ReminderPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func startsTodayWhenTheTimeIsStillAhead() {
        let dates = ReminderPlan.fireDates(after: date(28, 9), hour: 20, minute: 30, count: 3, calendar: calendar)
        #expect(dates == [date(28, 20, 30), date(29, 20, 30), date(30, 20, 30)])
    }

    @Test func startsTomorrowWhenTodaysTimeHasPassed() {
        let dates = ReminderPlan.fireDates(after: date(28, 21), hour: 20, minute: 0, count: 2, calendar: calendar)
        #expect(dates == [date(29, 20), date(30, 20)])
    }

    @Test func skipsWrittenDaysButKeepsTheCount() {
        let today = DayKey(year: 2026, month: 10, day: 28)
        let dates = ReminderPlan.fireDates(after: date(28, 9), hour: 20, minute: 0, count: 2, skipping: [today], calendar: calendar)
        #expect(dates == [date(29, 20), date(30, 20)])
    }
}

@MainActor
@Suite("Map and attachments")
struct MapAndAttachmentTests {
    @Test func mapPinsOnlyIncludeEntriesWithLocations() throws {
        let stores = try makeStores()
        let placed = stores.entries.create()
        stores.entries.setLocation(placed, latitude: 40.2, longitude: -111.6, placeName: "Provo")
        let unplaced = stores.entries.create()
        stores.entries.setTitle(unplaced, "No place")
        let deleted = stores.entries.create()
        stores.entries.setLocation(deleted, latitude: 1, longitude: 2, placeName: nil)
        stores.entries.softDelete(deleted)
        let pins = stores.entries.mapPins()
        #expect(pins.map(\.entryID) == [placed.id])
        #expect(pins.first?.latitude == 40.2)
        #expect(pins.first?.cover == nil)
    }

    @Test func mapPinUsesTheCoverPhoto() async throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setLocation(entry, latitude: 40.2, longitude: -111.6, placeName: nil)
        let imported = try await stores.media.importFile(at: try writeTestJPEG(), kind: .photo)
        stores.attachments.add(imported, to: entry)
        #expect(stores.entries.mapPins().first?.cover?.id == imported.id)
    }

    @Test func attachmentItemsAreNewestFirstAndFilterByKind() async throws {
        let stores = try makeStores()
        let old = stores.entries.create(date: .now.addingTimeInterval(-86_400 * 10))
        let new = stores.entries.create(date: .now)
        let photo = try await stores.media.importFile(at: try writeTestJPEG(), kind: .photo)
        stores.attachments.add(photo, to: old)
        let fileURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: fileURL)
        let file = try await stores.media.importFile(at: fileURL, originalFilename: "notes.txt")
        #expect(file.kind == .file)
        stores.attachments.add(file, to: new)

        let all = stores.attachments.allItems()
        #expect(all.map(\.id) == [file.id, photo.id])
        #expect(all.first?.entryID == new.id)
        #expect(all.first?.reference.originalFilename == "notes.txt")
        #expect(stores.attachments.allItems(kind: .photo).map(\.id) == [photo.id])
        #expect(stores.attachments.allItems(kind: .audio).isEmpty)
    }
}
