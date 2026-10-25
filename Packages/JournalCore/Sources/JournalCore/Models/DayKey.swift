import Foundation

/// A calendar day (year, month, day), independent of time zone.
///
/// An entry's day is computed in the time zone it was written in, so an entry written
/// at 11 pm in Tokyo stays on that day when viewed back home.
// DECISION: day keys always use the Gregorian calendar so they are stable across
// locale changes; display formatting still follows the user's calendar settings.
public struct DayKey: Hashable, Comparable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public static var today: DayKey { DayKey(date: .now) }

    public var id: String { description }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight at the start of this day in the given time zone.
    public func startDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// This day at the given time of day (taken from `time`), in the given time zone.
    public func date(atTimeOf time: Date, in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: clock.hour, minute: clock.minute, second: clock.second
        )) ?? startDate(in: timeZone)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// What the calendar needs to know about one day.
public struct DaySummary: Hashable, Sendable {
    /// Entry IDs on this day, earliest first.
    public var entryIDs: [UUID]
    /// The photo or video that fills the day's cell, if any.
    public var cover: MediaReference?

    public var count: Int { entryIDs.count }

    public init(entryIDs: [UUID], cover: MediaReference?) {
        self.entryIDs = entryIDs
        self.cover = cover
    }
}
