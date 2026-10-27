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

    /// The lock screen while locked; otherwise, whenever locking is on and the app isn't active,
    /// a plain cover so the app switcher never shows entries.
    private var lockCover: LockCover {
        if app.lock.isLocked { return .locked }
        if app.lock.isEnabled && scenePhase != .active { return .privacy }
        return .none
    }

    var body: some View {
        @Bindable var app = app
        RootTabView()
            // In a window of its own, above sheets and full-screen covers too.
            .background { LockWindowInstaller(cover: lockCover, isActive: scenePhase == .active, app: app) }
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
