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
                TabStack(tab: .map) { MapScreen() }
            }

            Tab("Attachments", systemImage: "square.grid.2x2", value: AppTab.attachments) {
                TabStack(tab: .attachments) { AttachmentsScreen() }
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
        // DECISION: entries open with the standard slide, not the zoom out of the calendar day. With
        // the zoom, iOS reported the page leaving about a second after it had visibly gone, so the
        // tab bar always came back late. The slide reports on time, and the bar fades with the swipe.
        case .entry(let id, _):
            EntryEditorScreen(entryID: id)
                // The path only changes once the back animation has finished, which made the tab bar
                // lag behind. These fire as the page starts leaving, and again if a swipe is cancelled.
                .background {
                    AppearanceEvents(
                        willAppear: { app.router.isLeavingEntry = false },
                        willDisappear: { app.router.isLeavingEntry = true }
                    )
                }
        case .day(let day, let source):
            DayListScreen(day: day)
                .steadyBottomInset(tabBarInset)
                .zoomTransition(from: source, in: zoom)
        case .onThisDay(let day):
            OnThisDayScreen(day: day)
                .steadyBottomInset(tabBarInset)
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

/// UIKit's will-appear and will-disappear callbacks, which SwiftUI doesn't offer, and the tab bar's
/// fade during the entry page's transitions. A back swipe reports will-disappear as soon as the
/// page starts to leave, and the transition coordinator says how far it has gone and how it ended.
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
        private weak var tabBar: UITabBar?
        private weak var nav: UINavigationController?
        /// The controller this page was pushed as, the direct child of the navigation controller.
        private weak var page: UIViewController?
        private weak var followedTransition: UIViewControllerTransitionCoordinator?
        private var displayLink: CADisplayLink?
        private var isWaitingForHide = false
        /// Set when the finger lifts: the fade to the transition's outcome.
        private var finish: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: TimeInterval)?

        // DECISION: one rule decides the tab bar. While a transition of this page runs, the bar
        // follows its progress. When it ends, the bar is set from the truth: is this page still the
        // top of the navigation stack? Swipe gestures aren't watched at all: a flick that starts no
        // transition (say, while the page is still zooming open) changes nothing, and guesses from
        // the gesture used to leave the bar stuck over the entry.

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            remember()
            willAppear()
        }

        // On a device the did-appear callback doesn't always reach this embedded controller, so
        // look up the navigation controller and page from every point that does run.
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            remember()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            remember()
            if followedTransition == nil { applyTruth("didAppear") }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            remember()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            followTransitionIfAny()
            // Make the bar see-through before SwiftUI shows it, or it appears at full strength
            // for a few frames before following the swipe.
            if followedTransition != nil { tabBar?.alpha = 0 }
            willDisappear()
            if followedTransition == nil {
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
            finish = nil
            startDisplayLink()
            // Progress stops updating when the finger lifts; animate the rest of the way from there.
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard let self else { return }
                let leaving = context.viewController(forKey: .from) === self.page
                let target: CGFloat = (leaving != context.isCancelled) ? 1 : 0
                let remaining = context.transitionDuration * (context.isCancelled ? context.percentComplete : 1 - context.percentComplete)
                self.finish = (from: self.tabBar?.alpha ?? target, to: target, start: CACurrentMediaTime(), duration: max(remaining, 0.1))
            }
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
            if followedTransition != nil, let finish {
                let t = min((CACurrentMediaTime() - finish.start) / finish.duration, 1)
                tabBar?.alpha = finish.from + (finish.to - finish.from) * t
            } else if let coordinator = followedTransition, let page {
                // The bar shows as much as the page has gone: fading in as it leaves, out as it arrives.
                let leaving = coordinator.viewController(forKey: .from) === page
                let shown = leaving ? coordinator.percentComplete : 1 - coordinator.percentComplete
                tabBar?.alpha = coordinator.isCancelled ? (leaving ? 0 : 1) : shown
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
                stopDisplayLink()
            }
        }

        isolated deinit {
            displayLink?.invalidate()
            if isWaitingForHide { tabBar?.alpha = 1 }
        }
    }
}
