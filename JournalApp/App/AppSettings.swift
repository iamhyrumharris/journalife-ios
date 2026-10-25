import JournalUI
import SwiftUI

/// UserDefaults keys for settings. Read with `@AppStorage(AppSettings.theme)` and so on.
enum AppSettings {
    static let theme = "appearance.theme"
    static let accent = "appearance.accent"
    static let serifBody = "appearance.serifBody"
    static let textSize = "appearance.textSize"
    static let timelineThumbnails = "timeline.showThumbnails"
    static let weekStart = "calendar.weekStart"
    static let lockEnabled = "security.lockEnabled"
    static let autoLockDelay = "security.autoLockDelay"
    static let recentSearches = "search.recent"
    static let timelineNewestFirst = "timeline.newestFirst"
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

enum WeekStart: Int, CaseIterable, Identifiable {
    /// Follow the system locale.
    case system = 0
    case sunday = 1
    case monday = 2
    case saturday = 7

    var id: Int { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .system: "System Default"
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .saturday: "Saturday"
        }
    }

    /// The calendar to lay out weeks with.
    var calendar: Calendar {
        var calendar = Calendar.current
        if self != .system { calendar.firstWeekday = rawValue }
        return calendar
    }
}

enum AutoLockDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        }
    }
}
