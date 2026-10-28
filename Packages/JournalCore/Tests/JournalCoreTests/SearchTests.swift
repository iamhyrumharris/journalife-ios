import Foundation
import Testing
@testable import JournalCore

@MainActor
@Suite("Search")
struct SearchTests {
    @Test func matchesWordsAnywhereIgnoringCaseAndAccents() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "Café morning")
        stores.entries.setBody(entry, richText: RichText(plain: "Walked to the PARK with Ana."))
        let other = stores.entries.create()
        stores.entries.setTitle(other, "Something else")

        #expect(stores.entries.search(SearchQuery(text: "cafe")).map(\.id) == [entry.id])
        #expect(stores.entries.search(SearchQuery(text: "park ana")).map(\.id) == [entry.id])
        #expect(stores.entries.search(SearchQuery(text: "ark")).map(\.id) == [entry.id])
        #expect(stores.entries.search(SearchQuery(text: "park zebra")).isEmpty)
    }

    @Test func emptyQueryMatchesAll() throws {
        let stores = try makeStores()
        stores.entries.setTitle(stores.entries.create(), "One")
        stores.entries.setTitle(stores.entries.create(), "Two")
        #expect(stores.entries.search(SearchQuery()).count == 2)
    }

    @Test func excludesDeletedEntries() throws {
        let stores = try makeStores()
        let entry = stores.entries.create()
        stores.entries.setTitle(entry, "secret")
        stores.entries.softDelete(entry)
        #expect(stores.entries.search(SearchQuery(text: "secret")).isEmpty)
    }

    @Test func filters() async throws {
        let stores = try makeStores()
        let tag = stores.tags.create(name: "Travel")
        let tagged = stores.entries.create()
        stores.entries.setTitle(tagged, "tagged")
        stores.entries.setTags(tagged, [tag])
        stores.entries.setRating(tagged, 5)

        let favorite = stores.entries.create(date: .now.addingTimeInterval(-86_400 * 10))
        stores.entries.setTitle(favorite, "favorite")
        stores.entries.toggleFavorite(favorite)
        stores.entries.setLocation(favorite, latitude: 1, longitude: 2, placeName: "Somewhere")

        let photo = stores.entries.create()
        stores.entries.setTitle(photo, "photo")
        stores.attachments.add(try await stores.media.importFile(at: try writeTestJPEG(), move: true), to: photo)

        var query = SearchQuery()
        query.tagIDs = [tag.id]
        #expect(stores.entries.search(query).map(\.id) == [tagged.id])

        query = SearchQuery()
        query.ratings = [5]
        #expect(stores.entries.search(query).map(\.id) == [tagged.id])

        query = SearchQuery()
        query.favoritesOnly = true
        query.hasLocation = true
        #expect(stores.entries.search(query).map(\.id) == [favorite.id])

        query = SearchQuery()
        query.hasPhotos = true
        #expect(stores.entries.search(query).map(\.id) == [photo.id])

        query = SearchQuery()
        query.dateRange = Date.now.addingTimeInterval(-86_400 * 11)...Date.now.addingTimeInterval(-86_400 * 9)
        #expect(stores.entries.search(query).map(\.id) == [favorite.id])
    }

    @Test func matchRangesForHighlighting() {
        let text = "Café and cafe and CAFÉ"
        let ranges = SearchMatcher.matchRanges(in: text, terms: SearchMatcher.terms(from: "cafe"))
        #expect(ranges.count == 3)
        #expect(ranges.map { String(text[$0]) } == ["Café", "cafe", "CAFÉ"])
    }
}
