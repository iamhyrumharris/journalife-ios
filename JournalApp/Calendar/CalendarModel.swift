import Foundation
import JournalCore
import Observation

/// One month in the calendar scroll.
struct CalendarMonth: Identifiable, Hashable {
    let year: Int
    let month: Int
    /// Empty cells before the 1st, so the 1st lands under the right weekday.
    let leadingBlanks: Int
    let dayCount: Int

    var id: String { String(format: "%04d-%02d", year, month) }
    var firstDay: DayKey { DayKey(year: year, month: month, day: 1) }

    func day(_ number: Int) -> DayKey { DayKey(year: year, month: month, day: number) }
}

/// What fills a day cell.
///
/// Later customization hook: a setting for what fills cells (photo, rating color, tag color,
/// mood). Only `CalendarModel.content(for:)` decides this, so it is the one place to change.
enum CalendarCellContent: Hashable {
    case photo(MediaReference)
    /// Has entries but no photo: a solid tinted cell.
    case tinted
    case empty
}

@MainActor
@Observable
final class CalendarModel {
    private(set) var months: [CalendarMonth] = []
    private(set) var summaries: [DayKey: DaySummary] = [:]
    private(set) var calendar = Calendar.current
    private var extraMonthsBack: DayKey?

    /// Rebuilds months and day summaries. Cheap enough to run after every save.
    func refresh(stores: JournalStores, weekStart: WeekStart) {
        calendar = weekStart.calendar
        summaries = stores.entries.daySummaries()
        months = Self.months(
            from: [stores.entries.earliestEntryDate().map { DayKey(date: $0) }, extraMonthsBack].compactMap { $0 }.min(),
            calendar: calendar
        )
    }

    /// Makes sure the calendar reaches back to a date (for Jump to Date).
    func ensureIncludes(_ day: DayKey, stores: JournalStores, weekStart: WeekStart) {
        if let current = months.first?.firstDay, day >= current { return }
        extraMonthsBack = day
        refresh(stores: stores, weekStart: weekStart)
    }

    /// Adds ten more years above the oldest month (the "Show Earlier Months" button).
    func loadEarlierMonths(stores: JournalStores, weekStart: WeekStart) {
        guard let first = months.first else { return }
        extraMonthsBack = DayKey(year: first.year - Self.yearsBack, month: first.month, day: 1)
        refresh(stores: stores, weekStart: weekStart)
    }

    func content(for day: DayKey) -> CalendarCellContent {
        guard let summary = summaries[day] else { return .empty }
        if let cover = summary.cover { return .photo(cover) }
        return .tinted
    }

    /// Short weekday names (Sun, Mon…) in display order, following the week start.
    var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var fullWeekdaySymbols: [String] {
        let symbols = calendar.standaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    /// How far back the calendar reaches with no older entries, and how much each "Show Earlier Months" adds.
    static let yearsBack = 10

    /// Every month from the earliest entry (at least ten years back) through the current month.
    static func months(from earliest: DayKey?, calendar: Calendar, now: Date = .now) -> [CalendarMonth] {
        let today = DayKey(date: now)
        let defaultStart = DayKey(year: today.year - yearsBack, month: 1, day: 1)
        let start = min(earliest ?? defaultStart, defaultStart)

        var result: [CalendarMonth] = []
        var year = start.year
        var month = start.month
        while (year, month) <= (today.year, today.month) {
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let weekday = calendar.component(.weekday, from: first)
            let blanks = (weekday - calendar.firstWeekday + 7) % 7
            let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
            result.append(CalendarMonth(year: year, month: month, leadingBlanks: blanks, dayCount: days))
            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
        }
        return result
    }
}
