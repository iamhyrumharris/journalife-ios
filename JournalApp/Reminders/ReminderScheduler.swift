import JournalCore
import UserNotifications

/// The daily writing reminder, scheduled as local notifications.
@MainActor
enum ReminderScheduler {
    static let defaultMinutes = 20 * 60
    private static let idPrefix = "daily-reminder-"
    private static let repeatingID = idPrefix + "repeating"
    /// How many days ahead to schedule when written days are skipped.
    private static let daysAhead = 30

    /// Asks for permission to show notifications. Returns whether reminders can be shown.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// Replaces any scheduled reminders with ones that match the current settings.
    /// Run at launch, when the app goes to the background and whenever reminder settings change.
    ///
    // DECISION: when written days are skipped, reminders can't repeat on their own, so the next
    // 30 days are scheduled one by one, leaving out today once there's an entry. Opening the app
    // at least once a month keeps them going. With "remind on written days" on, one repeating
    // reminder is used, which never runs out.
    static func reschedule(stores: JournalStores, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: scheduledIDs(around: now))

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.reminderEnabled) else { return }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let minutes = defaults.object(forKey: AppSettings.reminderTime) as? Int ?? defaultMinutes
        let hour = minutes / 60
        let minute = minutes % 60

        if defaults.bool(forKey: AppSettings.reminderOnWrittenDays) {
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
            try? await center.add(UNNotificationRequest(identifier: repeatingID, content: content(), trigger: trigger))
            return
        }

        let today = DayKey(date: now)
        let skipping: Set<DayKey> = stores.entries.hasWrittenEntry(on: today) ? [today] : []
        let calendar = Calendar.current
        for date in ReminderPlan.fireDates(after: now, hour: hour, minute: minute, count: daysAhead, skipping: skipping, calendar: calendar) {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            let id = idPrefix + DayKey(date: date).description
            try? await center.add(UNNotificationRequest(identifier: id, content: content(), trigger: trigger))
        }
    }

    /// Every id this scheduler could have used for a reminder that hasn't fired yet.
    private static func scheduledIDs(around now: Date) -> [String] {
        let calendar = Calendar.current
        let days = (-1...(daysAhead + 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        return [repeatingID] + days.map { idPrefix + DayKey(date: $0).description }
    }

    private static func content() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to write")
        content.body = String(localized: "How was your day? Take a minute to write it down.")
        content.sound = .default
        // DECISION: tapping the reminder opens a new entry, ready to write.
        content.userInfo = ["link": "journal://new"]
        return content
    }
}

/// Shows reminders while the app is open and opens their link when one is tapped.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    var onOpenLink: ((URL) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: link) else { return }
        await MainActor.run {
            self.onOpenLink?(url)
        }
    }
}
