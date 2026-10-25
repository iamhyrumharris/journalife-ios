import JournalCore
import JournalUI
import SwiftUI

@main
struct JournalApp: App {
    @State private var launch = AppLaunch.start()

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .ready(let model):
                AppRootView()
                    .environment(model)
            case .failed(let message):
                StoreErrorView(message: message)
            }
        }
    }
}

enum AppLaunch {
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func start() -> AppLaunch {
        do {
            return .ready(try AppModel.live())
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Applies appearance settings, the lock and the privacy overlay around the tabs.
struct AppRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.theme) private var theme = AppTheme.system
    @AppStorage(AppSettings.accent) private var accent = AccentChoice.blue
    @AppStorage(AppSettings.serifBody) private var serifBody = false
    @AppStorage(AppSettings.textSize) private var textSize = EntryTextSize.large
    @AppStorage(AppSettings.timelineThumbnails) private var timelineThumbnails = false

    var body: some View {
        @Bindable var app = app
        RootTabView()
            .overlay {
                if app.lock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                } else if app.lock.isEnabled && scenePhase != .active {
                    // Hides content in the app switcher snapshot whenever locking is on.
                    PrivacyCover()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: app.lock.isLocked)
            .tint(accent.color)
            .preferredColorScheme(theme.colorScheme)
            .environment(\.thumbnailCache, app.thumbnails)
            .environment(\.storageLocation, app.stores.location)
            .environment(\.showsRowThumbnails, timelineThumbnails)
            .environment(\.usesSerifBody, serifBody)
            .environment(\.entryTextSize, textSize)
            .sheet(isPresented: $app.isShowingSettings) {
                SettingsSheet()
                    .tint(accent.color)
                    .preferredColorScheme(theme.colorScheme)
            }
            .onOpenURL { app.handle(url: $0) }
            .onChange(of: scenePhase) { _, phase in
                app.lock.sceneDidChange(to: phase)
                if phase == .background { app.flushEditors() }
            }
    }
}

struct StoreErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Your journal couldn't be opened", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Nothing has been deleted. Try restarting the app. If this keeps happening, the details below will help fix it.\n\n\(message)")
        }
    }
}
