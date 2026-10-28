import Foundation
import Testing
@testable import JournalCore

@MainActor
@Suite("TagStore")
struct TagStoreTests {
    @Test func namesAreUniqueIgnoringCase() throws {
        let stores = try makeStores()
        let a = stores.tags.create(name: "Travel")
        let b = stores.tags.create(name: "  travel ")
        #expect(a.id == b.id)
        #expect(stores.tags.allTags().count == 1)
    }

    @Test func renameRejectsTakenNames() throws {
        let stores = try makeStores()
        let work = stores.tags.create(name: "Work")
        _ = stores.tags.create(name: "Family")
        #expect(stores.tags.rename(work, to: "family") == .nameTaken)
        #expect(stores.tags.rename(work, to: "") == .emptyName)
        #expect(stores.tags.rename(work, to: "Job") == .renamed)
        #expect(work.name == "Job")
    }

    @Test func mostUsedTagsAreOrderedByUse() throws {
        let stores = try makeStores()
        let unused = stores.tags.create(name: "Unused")
        let once = stores.tags.create(name: "Once")
        let twice = stores.tags.create(name: "Twice")
        let one = stores.entries.create()
        let two = stores.entries.create()
        stores.entries.setTags(one, [once, twice])
        stores.entries.setTags(two, [twice])

        let ids = stores.tags.mostUsedTags().map(\.id)
        #expect(ids == [twice.id, once.id])
        #expect(!ids.contains(unused.id))
        #expect(stores.tags.mostUsedTags(limit: 1).map(\.id) == [twice.id])
    }

    @Test func mergeMovesEntries() throws {
        let stores = try makeStores()
        let source = stores.tags.create(name: "Runs")
        let target = stores.tags.create(name: "Workout")
        let one = stores.entries.create()
        let two = stores.entries.create()
        stores.entries.setTags(one, [source])
        stores.entries.setTags(two, [source, target])

        stores.tags.merge(source, into: target)
        #expect(one.liveTags.map(\.id) == [target.id])
        #expect(two.liveTags.map(\.id) == [target.id])
        #expect(stores.tags.allTags().map(\.id) == [target.id])
    }

    @Test func reorderSavesSortOrder() throws {
        let stores = try makeStores()
        let a = stores.tags.create(name: "A")
        let b = stores.tags.create(name: "B")
        let c = stores.tags.create(name: "C")
        stores.tags.reorder([c, a, b])
        #expect(stores.tags.allTags().map(\.name) == ["C", "A", "B"])
    }
}
