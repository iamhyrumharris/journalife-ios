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

/// UIKit's will-appear and will-disappear callbacks, which SwiftUI doesn't offer, plus the start
/// of a back swipe. On a real device an interactive back swipe (edge or zoom dismiss) only reports
/// will-disappear when it finishes, so the swipe gesture itself is watched as well.
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
        private var watched: [UIGestureRecognizer] = []
        private weak var tabBar: UITabBar?
        private weak var nav: UINavigationController?
        /// The controller this page was pushed as, the direct child of the navigation controller.
        private weak var page: UIViewController?
        private weak var activePan: UIPanGestureRecognizer?
        private weak var followedTransition: UIViewControllerTransitionCoordinator?
        private var displayLink: CADisplayLink?
        private var isWaitingForHide = false

        // DECISION: one rule decides the tab bar. While a transition runs, the bar follows its
        // progress. When it ends (or a swipe ends without one starting), the bar is set from the
        // truth: is this page still the top of the navigation stack? Never from swipe speed or
        // timers; those guesses left the bar stuck over the entry after quick flicks.

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            remember()
            willAppear()
        }

        // On a device the did-appear callback doesn't always reach this embedded controller, so
        // hook in from every point that does run; watchBackGestures skips recognizers it has.
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            remember()
            watchBackGestures()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            remember()
            watchBackGestures()
            if activePan == nil && followedTransition == nil { applyTruth("didAppear") }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            remember()
            watchBackGestures()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            willDisappear()
            followTransitionIfAny()
            if followedTransition == nil && activePan == nil {
                // Leaving without an animation (for example switching tabs): the bar shows normally.
                stopDisplayLink()
                tabBar?.alpha = 1
            }
        }

        private func remember() {
            if let bar = tabBarController?.tabBar { tabBar = bar }
            if let nav = navigationController { self.nav = nav }
            var candidate: UIViewController? = self
            while let current = candidate, let parent = current.parent {
                if parent === nav { page = current; break }
                candidate = parent
            }
        }

        /// Adds this controller as an extra target of the back-swipe recognizers: the navigation
        /// controller's edge and content pops, and the pans on the page (the zoom dismiss).
        private func watchBackGestures() {
            var candidates: [UIGestureRecognizer] = []
            if let nav {
                candidates += [nav.interactivePopGestureRecognizer, nav.interactiveContentPopGestureRecognizer].compactMap { $0 }
            }
            var view = parent?.view
            while let current = view, current !== nav?.view.superview {
                candidates += (current.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
                view = current.superview
            }
            for recognizer in candidates where !watched.contains(where: { $0 === recognizer }) {
                recognizer.addTarget(self, action: #selector(backGestureChanged(_:)))
                watched.append(recognizer)
            }
        }

        @objc private func backGestureChanged(_ recognizer: UIGestureRecognizer) {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return }
            // The navigation controller's recognizers are shared by every page; only the top one acts.
            guard isOnTop else { return }
            switch pan.state {
            case .began:
                willDisappear()
                activePan = pan
                isWaitingForHide = false
                tabBar?.alpha = 0
                startDisplayLink()
            case .ended, .cancelled, .failed:
                activePan = nil
                // The display link takes it from here: it follows a transition if one runs, or
                // applies the truth on the next frame if none does.
            default:
                break
            }
        }

        private var currentCoordinator: UIViewControllerTransitionCoordinator? {
            nav?.transitionCoordinator ?? page?.transitionCoordinator
        }

        /// Whether this page is the top of its navigation stack: the one fact the bar follows.
        private var isOnTop: Bool {
            guard let nav, let page else { return false }
            return nav.topViewController === page
        }

        private func followTransitionIfAny() {
            guard followedTransition == nil, let coordinator = currentCoordinator, let page else { return }
            // Only a transition this page takes part in. Pages closed earlier can still be in memory
            // and hear the navigation controller's transitions; they must leave the bar alone.
            guard coordinator.viewController(forKey: .from) === page || coordinator.viewController(forKey: .to) === page else { return }
            followedTransition = coordinator
            startDisplayLink()
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }
                self.followedTransition = nil
                self.applyTruth("transition ended")
            }
        }

        /// Sets the bar from whether the page is on top: hidden if it is, shown if it isn't.
        private func applyTruth(_ reason: String) {
            // A page no longer in the stack has nothing to say about the bar.
            guard let nav, nav.viewControllers.contains(where: { $0 === page }) || reason == "transition ended" else {
                isWaitingForHide = false
                stopDisplayLink()
                return
            }
            let onTop = isOnTop
            if onTop {
                willAppear()
                // SwiftUI hides the bar a moment later; keep it see-through until then.
                tabBar?.alpha = 0
                isWaitingForHide = true
                startDisplayLink()
            } else {
                isWaitingForHide = false
                stopDisplayLink()
                tabBar?.alpha = 1
            }
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            followTransitionIfAny()
            if let coordinator = followedTransition {
                // Leaving: the bar shows as much as the page has gone.
                tabBar?.alpha = coordinator.isCancelled ? 0 : coordinator.percentComplete
            } else if let pan = activePan {
                // The finger is down but no transition has started yet.
                tabBar?.alpha = swipeProgress(pan)
            } else if isWaitingForHide {
                guard let bar = tabBar else { return stopDisplayLink() }
                if !isOnTop {
                    isWaitingForHide = false
                    stopDisplayLink()
                    bar.alpha = 1
                } else if bar.isHidden || bar.window == nil {
                    // Hidden by SwiftUI now, so it can be opaque for whenever it next shows.
                    isWaitingForHide = false
                    stopDisplayLink()
                    bar.alpha = 1
                } else {
                    bar.alpha = 0
                }
            } else {
                // The swipe ended and no transition ran: nothing moved, so apply the truth.
                applyTruth("swipe without transition")
            }
        }

        private func swipeProgress(_ pan: UIPanGestureRecognizer) -> CGFloat {
            let translation = pan.translation(in: view)
            let bounds = view.window?.bounds ?? view.bounds
            let progress = max(translation.x / bounds.width, translation.y / bounds.height)
            return min(max(progress, 0), 1)
        }

        isolated deinit {
            displayLink?.invalidate()
            if isWaitingForHide { tabBar?.alpha = 1 }
            for recognizer in watched { recognizer.removeTarget(self, action: nil) }
        }
    }
}
