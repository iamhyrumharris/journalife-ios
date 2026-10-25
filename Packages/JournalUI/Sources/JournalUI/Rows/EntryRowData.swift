import Foundation
import JournalCore

/// Everything a list row shows about an entry, copied out of the model so rows are cheap
/// to render and easy to preview.
public struct EntryRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let timeZone: TimeZone
    public let title: String
    public let preview: String
    public let isFavorite: Bool
    public let rating: Int?
    public let thumbnail: MediaReference?

    public init(id: UUID, date: Date, timeZone: TimeZone, title: String, preview: String,
                isFavorite: Bool = false, rating: Int? = nil, thumbnail: MediaReference? = nil) {
        self.id = id
        self.date = date
        self.timeZone = timeZone
        self.title = title
        self.preview = preview
        self.isFavorite = isFavorite
        self.rating = rating
        self.thumbnail = thumbnail
    }

    @MainActor
    public init(_ entry: Entry) {
        self.init(
            id: entry.id,
            date: entry.entryDate,
            timeZone: entry.timeZone,
            title: entry.displayTitle,
            preview: entry.previewText,
            isFavorite: entry.isFavorite,
            rating: entry.rating,
            thumbnail: entry.coverAttachment?.reference
        )
    }

    /// The month this row is grouped under ("October 2026"), in the entry's time zone.
    public var monthKey: DayKey {
        let day = DayKey(date: date, timeZone: timeZone)
        return DayKey(year: day.year, month: day.month, day: 1)
    }
}

public extension Date {
    /// Formats in a specific time zone, so entries show the day they were written on.
    func formatted(_ style: Date.FormatStyle, in timeZone: TimeZone) -> String {
        var style = style
        style.timeZone = timeZone
        return formatted(style)
    }
}

public extension DayKey {
    /// "October 2026"
    var monthTitle: String {
        startDate().formatted(.dateTime.month(.wide).year())
    }
}
