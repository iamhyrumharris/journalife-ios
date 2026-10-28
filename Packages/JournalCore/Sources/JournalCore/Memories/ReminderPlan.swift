import Foundation

/// Works out when the daily writing reminder should fire.
public enum ReminderPlan {
    /// The next `count` reminder times at `hour:minute`, starting today if that time is still
    /// ahead, and leaving out any day in `skipping` (days already written, when the user
    /// doesn't want a reminder on those).
    public static func fireDates(
        after now: Date,
        hour: Int,
        minute: Int,
        count: Int,
        skipping: Set<DayKey> = [],
        calendar: Calendar = .current
    ) -> [Date] {
        var result: [Date] = []
        var dayStart = calendar.startOfDay(for: now)
        // Look a little further than `count` days so skipped days don't shorten the plan.
        for _ in 0..<(count + skipping.count + 1) {
            guard result.count < count else { break }
            if let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart),
               fire > now,
               !skipping.contains(DayKey(date: fire, timeZone: calendar.timeZone)) {
                result.append(fire)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = next
        }
        return result
    }
}
