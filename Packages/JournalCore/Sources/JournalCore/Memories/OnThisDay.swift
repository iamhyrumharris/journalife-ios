import Foundation

/// Which past days count as "on this day" for a given day.
public enum OnThisDay {
    /// True when `candidate` falls on the same month and day as `day`, in an earlier year.
    ///
    // DECISION: on February 28 of a non-leap year, entries from February 29 count too,
    // so leap-day entries still come back three years out of four.
    public static func matches(_ candidate: DayKey, on day: DayKey) -> Bool {
        guard candidate.year < day.year else { return false }
        if candidate.month == day.month && candidate.day == day.day { return true }
        return day.month == 2 && day.day == 28 && !isLeapYear(day.year)
            && candidate.month == 2 && candidate.day == 29
    }

    /// How many years back a past day is, counted from `day`.
    public static func yearsAgo(_ candidate: DayKey, from day: DayKey) -> Int {
        day.year - candidate.year
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}
