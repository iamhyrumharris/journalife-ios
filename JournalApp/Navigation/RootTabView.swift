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
        private weak var activePan: UIPanGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var fade: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: TimeInterval)?
        private var isFollowingTransition = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            willAppear()
        }

        // On a device the did-appear callback doesn't always reach this embedded controller, so
        // hook in from every point that does run; watchBackGestures skips recognizers it has.
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            watchBackGestures()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            watchBackGestures()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            watchBackGestures()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            willDisappear()
            // Leaving by the back button rather than a swipe: show the bar normally.
            if activePan == nil && !isFollowingTransition {
                stopDisplayLink()
                tabBar?.alpha = 1
            }
        }

        /// Adds this controller as an extra target of the back-swipe recognizers: the navigation
        /// controller's edge and content pops, and the pans on the page (the zoom dismiss).
        private func watchBackGestures() {
            if let bar = tabBarController?.tabBar { tabBar = bar }
            var candidates: [UIGestureRecognizer] = []
            if let nav = navigationController {
                candidates += [nav.interactivePopGestureRecognizer, nav.interactiveContentPopGestureRecognizer].compactMap { $0 }
            }
            var view = parent?.view
            while let current = view, current !== navigationController?.view.superview {
                candidates += (current.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
                view = current.superview
            }
            for recognizer in candidates where !watched.contains(where: { $0 === recognizer }) {
                recognizer.addTarget(self, action: #selector(backGestureChanged(_:)))
                watched.append(recognizer)
            }
        }

        @objc private func backGestureChanged(_ recognizer: UIGestureRecognizer) {
            guard view.window != nil, let pan = recognizer as? UIPanGestureRecognizer else { return }
            // The tab bar fades in with the swipe, like the system's hidesBottomBarWhenPushed.
            switch pan.state {
            case .began:
                willDisappear()
                activePan = pan
                fade = nil
                tabBar?.alpha = 0
                startDisplayLink()
                watchTransitionOutcome()
            case .ended, .cancelled, .failed:
                activePan = nil
                // Normally the transition coordinator reports the outcome (see watchTransitionOutcome).
                // Without one, guess from the swipe, as before.
                if !isFollowingTransition {
                    let velocity = pan.velocity(in: view)
                    let finishing = pan.state == .ended
                        && (swipeProgress(pan) > 0.5 || max(velocity.x, velocity.y) > 300)
                    fadeTabBar(to: finishing ? 1 : 0, over: 0.25)
                    settle(finishing: finishing)
                }
            default:
                break
            }
        }

        /// DECISION: UIKit decides at finger lift whether a back swipe finishes or cancels, and the
        /// transition coordinator says which. Guessing from the swipe instead sometimes got it wrong,
        /// and waiting for the animation to end left SwiftUI showing the bar at full strength over
        /// the page for about a second after a cancel. Now the bar follows the real outcome at once.
        private func watchTransitionOutcome() {
            let coordinator = navigationController?.transitionCoordinator ?? parent?.transitionCoordinator
            guard let coordinator, coordinator.isInteractive else { return }
            isFollowingTransition = true
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard let self else { return }
                self.activePan = nil
                let remaining = context.transitionDuration * (1 - context.percentComplete)
                self.fadeTabBar(to: context.isCancelled ? 0 : 1, over: max(remaining, 0.15))
            }
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }
                self.isFollowingTransition = false
                if context.isCancelled {
                    // Still on the entry: hide the bar again, and keep it see-through until SwiftUI has.
                    self.willAppear()
                    self.holdHiddenUntilSwiftUIHides()
                } else {
                    self.stopDisplayLink()
                    self.tabBar?.alpha = 1
                }
            }
        }

        /// Fades the bar toward a target. Driven by the display link, because SwiftUI sets the bar
        /// back to full opacity on its own schedule while the page is leaving.
        private func fadeTabBar(to target: CGFloat, over duration: TimeInterval) {
            fade = (from: tabBar?.alpha ?? 0, to: target, start: CACurrentMediaTime(), duration: duration)
            startDisplayLink()
        }

        private func holdHiddenUntilSwiftUIHides(waited: TimeInterval = 0) {
            fade = (from: 0, to: 0, start: CACurrentMediaTime(), duration: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let bar = self.tabBar else { return }
                let window = bar.window
                let isGone = bar.isHidden || window == nil || bar.convert(bar.bounds, to: window).minY >= window!.bounds.height
                if !isGone && waited < 2 && self.activePan == nil && !self.isFollowingTransition {
                    self.holdHiddenUntilSwiftUIHides(waited: waited + 0.1)
                    return
                }
                guard self.activePan == nil && !self.isFollowingTransition else { return }
                self.stopDisplayLink()
                bar.alpha = 1
            }
        }

        /// The fallback when there's no transition coordinator: wait until the animation is over.
        /// If the page is still on top then, the swipe was cancelled.
        private func settle(finishing: Bool, waited: TimeInterval = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let nav = self.navigationController
                let stillRunning = nav?.transitionCoordinator != nil || self.parent?.transitionCoordinator != nil
                let isOnTop = self.view.window != nil && nav?.topViewController === self.parent
                if (stillRunning || (finishing && isOnTop)) && waited < 2 {
                    self.settle(finishing: finishing, waited: waited + 0.1)
                    return
                }
                if isOnTop {
                    self.willAppear()
                    self.holdHiddenUntilSwiftUIHides()
                } else {
                    self.stopDisplayLink()
                    self.tabBar?.alpha = 1
                }
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
            fade = nil
        }

        @objc private func tick() {
            if let pan = activePan {
                tabBar?.alpha = swipeProgress(pan)
            } else if let fade {
                let t = fade.duration > 0 ? min((CACurrentMediaTime() - fade.start) / fade.duration, 1) : 1
                tabBar?.alpha = fade.from + (fade.to - fade.from) * t
            }
        }

        /// How far the back swipe has gone, 0 to 1: sideways for the edge swipe, down for the zoom.
        private func swipeProgress(_ pan: UIPanGestureRecognizer) -> CGFloat {
            let translation = pan.translation(in: view)
            let bounds = view.window?.bounds ?? view.bounds
            let progress = max(translation.x / bounds.width, translation.y / bounds.height)
            return min(max(progress, 0), 1)
        }

        isolated deinit {
            displayLink?.invalidate()
            for recognizer in watched { recognizer.removeTarget(self, action: nil) }
        }
    }
}

