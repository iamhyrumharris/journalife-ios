import JournalCore
import SwiftUI

/// The sync button at the left of every tab's top bar: shows when sync is running or failed,
/// and opens a menu with the last sync time, any error, and Sync Now.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var app

    private var symbol: String {
        if app.sync.lastError != nil && !app.sync.isSyncing { return "exclamationmark.arrow.triangle.2.circlepath" }
        return "arrow.triangle.2.circlepath"
    }

    var body: some View {
        let sync = app.sync
        Menu {
            Section {
                Text(sync.statusText)
                if let error = sync.lastError, !sync.isSyncing {
                    Text(error)
                }
            }
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(sync.isSyncing)
            Button {
                app.isShowingSettings = true
            } label: {
                Label("Sync Settings", systemImage: "gearshape")
            }
        } label: {
            Label("Sync", systemImage: symbol)
                .symbolEffect(.rotate, isActive: sync.isSyncing)
                .foregroundStyle(sync.lastError != nil && !sync.isSyncing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        }
        .accessibilityLabel(Text("Sync: \(sync.statusText)"))
    }
}
