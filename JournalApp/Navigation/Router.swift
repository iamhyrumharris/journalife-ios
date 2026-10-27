import JournalCore
import Observation
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case calendar, timeline, map, attachments, search
}

/// Requests from the Calendar tab's ••• menu, which lives in the shared top bar.
enum CalendarCommand: Hashable {
    case jumpToToday, pickDate
}

/// Screens pushed onto a tab's stack. `zoomSource` names the view the zoom transition starts from.
enum AppRoute: Hashable {
    case entry(UUID, zoomSource: String? = nil)
    case day(DayKey, zoomSource: String? = nil)
}

/// One navigation stack above the tabs: pushed pages cover the whole tab view, tab bar included.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .calendar
    /// True from the moment an entry page starts going away (a back swipe or the back button)
    /// until it's back on screen or gone. The editor ignores taps meanwhile.
    var isLeavingEntry = false
    /// Set by the Calendar ••• menu; the calendar handles it and clears it.
    var calendarCommand: CalendarCommand?
    /// The Timeline ••• menu's tag filter.
    var timelineTagFilter: UUID?
    var path: [AppRoute] = [] {
        didSet {
            // Routes are popped from the end; anything past the shared prefix is gone.
            let shared = zip(oldValue, path).prefix { $0 == $1 }.count
            let removed = Array(oldValue.dropFirst(shared))
            if !removed.isEmpty { onRoutesRemoved?(removed) }
        }
    }

    /// Called with the routes that were popped, so the app can save and clean up empty entries.
    @ObservationIgnored var onRoutesRemoved: (([AppRoute]) -> Void)?

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// True if the stack shows this entry.
    func isShowing(entryID: UUID) -> Bool {
        path.contains { if case .entry(let id, _) = $0 { id == entryID } else { false } }
    }
}
