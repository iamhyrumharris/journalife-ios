import SwiftUI
import UIKit

/// What covers the app: the lock screen, the app-switcher cover, or nothing.
enum LockCover: Equatable {
    case none, locked, privacy
}

/// Shows the lock screen in its own window above everything else. As an overlay on the root
/// view it sat under sheets and full-screen covers, so Settings stayed usable while locked.
struct LockWindowInstaller: UIViewRepresentable {
    let cover: LockCover
    /// Passed in because a separate window's views don't follow the scene's phase.
    let isActive: Bool
    let app: AppModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        let cover = cover
        let isActive = isActive
        let app = app
        // The view gets its window a moment after it's created.
        DispatchQueue.main.async {
            coordinator.update(cover: cover, isActive: isActive, app: app, scene: view.window?.windowScene)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var window: UIWindow?
        private var host: UIHostingController<AnyView>?

        func update(cover: LockCover, isActive: Bool, app: AppModel, scene: UIWindowScene?) {
            if window == nil, let scene {
                let host = UIHostingController(rootView: AnyView(EmptyView()))
                host.view.backgroundColor = .clear
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.backgroundColor = .clear
                window.rootViewController = host
                self.window = window
                self.host = host
            }
            guard let window, let host else { return }
            host.rootView = AnyView(LockLayer(cover: cover, isActive: isActive).environment(app))
            window.isHidden = cover == .none
        }
    }
}

private struct LockLayer: View {
    let cover: LockCover
    let isActive: Bool

    var body: some View {
        switch cover {
        case .locked: LockScreenView(isActive: isActive)
        case .privacy: PrivacyCover()
        case .none: Color.clear
        }
    }
}
