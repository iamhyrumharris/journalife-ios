import BackgroundTasks
import JournalCore
import UIKit

/// Background app refresh for sync, and a short grace period to finish syncing when the app
/// goes to the background right after an edit.
@MainActor
enum BackgroundSync {
    /// Listed in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let refreshIdentifier = (Bundle.main.bundleIdentifier ?? "journalife") + ".sync"

    /// Asks iOS to wake the app in about an hour to sync.
    static func schedule(enabled: Bool) {
        guard enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails in the simulator and when background refresh is off; sync still runs in the foreground.
        }
    }

    /// Runs from background app refresh.
    // DECISION: refresh only syncs when the app is still in memory (the usual case). A cold
    // background launch doesn't build the journal just to sync; the next launch syncs anyway.
    static func run() async {
        guard let model = AppModel.current, model.sync.isEnabled else { return }
        schedule(enabled: true)
        // Media files are locked with the phone (complete file protection), so only records sync then.
        await model.sync.syncNow(includeFiles: UIApplication.shared.isProtectedDataAvailable)
    }

    /// Keeps the app awake for a few seconds after going to the background so the last edits get sent.
    static func finishInBackground(_ sync: SyncController) {
        guard sync.isEnabled else { return }
        let task = Box()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "Sync") {
            UIApplication.shared.endBackgroundTask(task.id)
            task.id = .invalid
        }
        Task {
            await sync.syncNow(includeFiles: UIApplication.shared.isProtectedDataAvailable)
            if task.id != .invalid { UIApplication.shared.endBackgroundTask(task.id) }
            task.id = .invalid
        }
    }

    @MainActor
    private final class Box {
        var id = UIBackgroundTaskIdentifier.invalid
    }
}
