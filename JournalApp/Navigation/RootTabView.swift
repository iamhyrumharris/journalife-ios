import UIKit
import JournalUI
import SwiftUI

/// Five tabs with the floating iOS 26 glass tab bar, inside one navigation stack.
// DECISION: pages (entries, day lists) are pushed on a stack that wraps the whole TabView, not on
// a stack per tab. A pushed page covers the tab bar, and swiping back reveals the tabs, bar
// included, from behind. The bar is never hidden or faded, so it can't get stuck over an entry.
// The trade-off: one stack for the app, so switching tabs always starts from the tab's root.
struct RootTabView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.timelineNewestFirst) private var timelineNewestFirst = true
    @Namespace private var zoom

    var body: some View {
        @Bindable var router = app.router
        NavigationStack(path: $router.path) {
            TabView(selection: $router.selectedTab) {
                Tab("Calendar", systemImage: "calendar", value: AppTab.calendar) {
                    tabRoot { CalendarScreen() }
                }

                Tab("Timeline", systemImage: "list.bullet.rectangle", value: AppTab.timeline) {
                    tabRoot { TimelineScreen() }
                }

                Tab("Map", systemImage: "map", value: AppTab.map) {
                    tabRoot {
                        ComingSoonView(title: "Map is coming soon", systemImage: "map",
                                       message: "Entries with a location will show up here as pins in the next update.")
                    }
                }

                Tab("Attachments", systemImage: "square.grid.2x2", value: AppTab.attachments) {
                    tabRoot {
                        ComingSoonView(title: "Attachments are coming soon", systemImage: "square.grid.2x2",
                                       message: "Every photo, video, recording and file from your entries will show up here in the next update.")
                    }
                }

                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                    tabRoot { SearchScreen() }
                }
            }
            // The tabs' pages are hosted apart from this stack, so their toolbars wouldn't reach its
            // bar. The shared top bar is set here instead, for whichever tab is showing.
            .modifier(TabRootToolbar(title: title(for: router.selectedTab), showsMenu: [.calendar, .timeline].contains(router.selectedTab)) {
                menu(for: router.selectedTab)
            })
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
        .environment(\.zoomNamespace, zoom)
    }

    private func title(for tab: AppTab) -> LocalizedStringResource {
        switch tab {
        case .calendar: "Calendar"
        case .timeline: "Timeline"
        case .map: "Map"
        case .attachments: "Attachments"
        case .search: "Search"
        }
    }

    /// The ••• menu for each tab (none for Map, Attachments and Search).
    @ViewBuilder
    private func menu(for tab: AppTab) -> some View {
        @Bindable var router = app.router
        switch tab {
        case .calendar:
            Button { router.calendarCommand = .jumpToToday } label: {
                Label("Jump to Today", systemImage: "calendar.badge.clock")
            }
            Button { router.calendarCommand = .pickDate } label: {
                Label("Jump to Date…", systemImage: "calendar.badge.magnifyingglass")
            }
        case .timeline:
            Picker(selection: $timelineNewestFirst) {
                Text("Newest First").tag(true)
                Text("Oldest First").tag(false)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            Picker(selection: $router.timelineTagFilter) {
                Text("All Entries").tag(UUID?.none)
                ForEach(app.stores.tags.allTags()) { tag in
                    Label(tag.name, systemImage: tag.symbolName).tag(UUID?.some(tag.id))
                }
            } label: {
                Label("Filter by Tag", systemImage: "line.3.horizontal.decrease")
            }
            .pickerStyle(.menu)
        case .map, .attachments, .search:
            EmptyView()
        }
    }

    private func tabRoot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().background(JournalColors.background)
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .entry(let id, let source):
            EntryEditorScreen(entryID: id)
                // Fire as the page starts leaving (and again if a swipe is cancelled), sooner than
                // the path changes, so the editor can ignore taps on its way out.
                .background {
                    AppearanceEvents(
                        willAppear: { app.router.isLeavingEntry = false },
                        willDisappear: { app.router.isLeavingEntry = true }
                    )
                }
                .zoomTransition(from: source, in: zoom)
        case .day(let day, let source):
            DayListScreen(day: day)
                .zoomTransition(from: source, in: zoom)
        }
    }
}

extension EnvironmentValues {
    /// The current tab's namespace, for `matchedTransitionSource` on cells and tiles.
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    @ViewBuilder
    func zoomTransition(from source: String?, in namespace: Namespace.ID) -> some View {
        if let source {
            navigationTransition(.zoom(sourceID: source, in: namespace))
        } else {
            self
        }
    }

    /// Marks a view as the start of a zoom transition, when the tab provides a namespace.
    @ViewBuilder
    func zoomSource(id: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

#Preview {
    RootTabView()
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}

/// UIKit's will-appear and will-disappear callbacks, which SwiftUI doesn't offer. A back swipe
/// reports will-disappear as soon as the page starts to leave, and will-appear if it's cancelled.
private struct AppearanceEvents: UIViewControllerRepresentable {
    var willAppear: () -> Void
    var willDisappear: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.willAppear = willAppear
        controller.willDisappear = willDisappear
    }

    final class Controller: UIViewController {
        var willAppear: () -> Void = {}
        var willDisappear: () -> Void = {}

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            willAppear()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            willDisappear()
        }
    }
}
