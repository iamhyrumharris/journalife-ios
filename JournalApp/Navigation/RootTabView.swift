import UIKit
import JournalUI
import SwiftUI

/// Five tabs with the floating iOS 26 glass tab bar. Each tab owns its own stack.
struct RootTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        TabView(selection: $router.selectedTab) {
            Tab("Calendar", systemImage: "calendar", value: AppTab.calendar) {
                TabStack(tab: .calendar) { CalendarScreen() }
            }

            Tab("Timeline", systemImage: "list.bullet.rectangle", value: AppTab.timeline) {
                TabStack(tab: .timeline) { TimelineScreen() }
            }

            Tab("Map", systemImage: "map", value: AppTab.map) {
                TabStack(tab: .map) {
                    ComingSoonView(title: "Map is coming soon", systemImage: "map",
                                   message: "Entries with a location will show up here as pins in the next update.")
                        .tabRootToolbar(title: "Map")
                }
            }

            Tab("Attachments", systemImage: "square.grid.2x2", value: AppTab.attachments) {
                TabStack(tab: .attachments) {
                    ComingSoonView(title: "Attachments are coming soon", systemImage: "square.grid.2x2",
                                   message: "Every photo, video, recording and file from your entries will show up here in the next update.")
                        .tabRootToolbar(title: "Attachments")
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                TabStack(tab: .search) { SearchScreen() }
            }
        }
    }
}

/// A tab's NavigationStack, with every route's destination and the zoom transition.
struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder var root: () -> Root

    @Environment(AppModel.self) private var app
    @Namespace private var zoom
    /// The bottom safe area with the tab bar showing. Screens under the tab bar keep this inset
    /// even while it's hidden, so it coming back never shifts their content.
    @State private var tabBarInset: CGFloat = 0

    /// The entry page gets the full screen, with no tab bar under it.
    private var isEntryOnTop: Bool {
        if case .entry = app.router.path(for: tab).wrappedValue.last { true } else { false }
    }

    private var hidesTabBar: Bool { isEntryOnTop && !app.router.isLeavingEntry }

    var body: some View {
        NavigationStack(path: app.router.path(for: tab)) {
            root()
                .steadyBottomInset(tabBarInset)
                .background(JournalColors.background)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        // Driven by the path rather than by the entry page itself: a per-page setting is applied
        // only after the swipe-back animation settles, and fast swipes sometimes lost it entirely.
        .toolbarVisibility(hidesTabBar ? .hidden : .visible, for: .tabBar)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            if !isEntryOnTop { tabBarInset = max(tabBarInset, inset) }
        }
        .environment(\.zoomNamespace, zoom)
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .entry(let id, let source):
            EntryEditorScreen(entryID: id)
                // The path only changes once the back animation has finished, which made the tab bar
                // lag behind. These fire as the page starts leaving, and again if a swipe is cancelled.
                .background {
                    AppearanceEvents(
                        willAppear: { app.router.isLeavingEntry = false },
                        willDisappear: { app.router.isLeavingEntry = true }
                    )
                }
                .zoomTransition(from: source, in: zoom)
        case .day(let day, let source):
            DayListScreen(day: day)
                .steadyBottomInset(tabBarInset)
                .zoomTransition(from: source, in: zoom)
        }
    }
}

extension EnvironmentValues {
    /// The current tab's namespace, for `matchedTransitionSource` on cells and tiles.
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Replaces the bottom container safe area with a fixed inset (once it's known).
    @ViewBuilder
    func steadyBottomInset(_ inset: CGFloat) -> some View {
        if inset > 0 {
            safeAreaPadding(.bottom, inset).ignoresSafeArea(.container, edges: .bottom)
        } else {
            self
        }
    }

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

/// UIKit's will-appear and will-disappear callbacks, which SwiftUI doesn't offer. They fire at the
/// start of a push, pop or interactive swipe, and a cancelled swipe brings back a will-appear.
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
