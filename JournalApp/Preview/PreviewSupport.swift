import JournalCore
import SwiftUI

/// An in-memory journal with sample entries, for SwiftUI previews.
@MainActor
enum PreviewSupport {
    static let model: AppModel = {
        let stores = try! JournalStores.inMemory()
        let tags = [
            stores.tags.create(name: "Family", colorHex: "#FF9F0A", symbolName: "person.2"),
            stores.tags.create(name: "Travel", colorHex: "#32D74B", symbolName: "airplane"),
            stores.tags.create(name: "Work", colorHex: "#0A84FF", symbolName: "briefcase"),
        ]
        let samples: [(String, String, Int)] = [
            ("Morning walk", "The light was soft over the hills. I made coffee and read for a while before everyone woke up.", 0),
            ("Family dinner", "Grandma made her famous rolls. We talked about planning a trip next summer, maybe somewhere with mountains and a lake.", 0),
            ("", "Quick note: finished the project I'd been worrying about for weeks. It felt great to finally ship it.", 1),
            ("Zion", "Hiked the Narrows with friends. Freezing water, amazing walls.", 9),
            ("Rainy afternoon", "Stayed in with a movie and a big bowl of popcorn.", 32),
            ("Back to work", "Busy but good. New team members started this week.", 61),
        ]
        for (index, sample) in samples.enumerated() {
            let date = Calendar.current.date(byAdding: .day, value: -sample.2, to: .now) ?? .now
            let entry = stores.entries.create(date: date)
            stores.entries.setTitle(entry, sample.0)
            stores.entries.setBody(entry, richText: RichText(plain: sample.1))
            stores.entries.setTags(entry, [tags[index % tags.count]])
            if index == 3 {
                stores.entries.setRating(entry, 5)
                stores.entries.setLocation(entry, latitude: 37.30, longitude: -113.03, placeName: "Zion National Park")
            }
        }
        return AppModel(stores: stores)
    }()

    static var firstEntryID: UUID {
        model.stores.entries.allEntries().first?.id ?? UUID()
    }
}
