import JournalCore
import Observation
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case calendar, timeline, map, attachments, search
}

/// Screens pushed onto a tab's stack. `zoomSource` names the view the zoom transition starts from.
enum AppRoute: Hashable {
    case entry(UUID, zoomSource: String? = nil)
    case day(DayKey, zoomSource: String? = nil)
    /// Entries from this date in earlier years.
    case onThisDay(DayKey)
}

/// One navigation stack per tab.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .calendar
    /// True from the moment an entry page starts going away (a back swipe or the back button)
    /// until it's back on screen or gone, so the tab bar can return with it instead of after.
    var isLeavingEntry = false
    private(set) var paths: [AppTab: [AppRoute]] = [:]

    /// Called with the routes that were popped, so the app can save and clean up empty entries.
    @ObservationIgnored var onRoutesRemoved: (([AppRoute]) -> Void)?

    func path(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { self.paths[tab, default: []] },
            set: { self.setPath($0, for: tab) }
        )
    }

    /// Pushes onto the current tab.
    func push(_ route: AppRoute) {
        var path = paths[selectedTab, default: []]
        path.append(route)
        setPath(path, for: selectedTab)
    }

    func pop() {
        var path = paths[selectedTab, default: []]
        guard !path.isEmpty else { return }
        path.removeLast()
        setPath(path, for: selectedTab)
    }

    /// True if any tab's stack shows this entry.
    func isShowing(entryID: UUID) -> Bool {
        paths.values.contains { path in
            path.contains { if case .entry(let id, _) = $0 { id == entryID } else { false } }
        }
    }

    private func setPath(_ newPath: [AppRoute], for tab: AppTab) {
        let old = paths[tab, default: []]
        paths[tab] = newPath
        // Routes are popped from the end; anything past the shared prefix is gone.
        let shared = zip(old, newPath).prefix { $0 == $1 }.count
        let removed = Array(old.dropFirst(shared))
        if !removed.isEmpty { onRoutesRemoved?(removed) }
    }
}
