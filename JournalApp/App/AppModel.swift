import JournalCore
import JournalUI
import Observation
import SwiftUI
import UserNotifications

/// App-wide state: the stores, navigation, the lock and the shared thumbnail cache.
@MainActor
@Observable
final class AppModel {
    let stores: JournalStores
    let thumbnails: ThumbnailCache
    let router = Router()
    let lock = AppLock()
    var isShowingSettings = false
    /// Opens reminder links. Kept here because the notification center holds its delegate weakly.
    @ObservationIgnored private let notificationResponder = NotificationResponder()

    /// Open editors, so their pending text can be saved before the app backgrounds.
    @ObservationIgnored private var editors: [UUID: WeakEditor] = [:]
    /// New entries that should open without focusing the title (see `createEntry`).
    @ObservationIgnored private(set) var unfocusedNewEntries: Set<UUID> = []

    init(stores: JournalStores) {
        self.stores = stores
        self.thumbnails = ThumbnailCache(location: stores.location)
        router.onRoutesRemoved = { [weak self] routes in self?.routesRemoved(routes) }
        notificationResponder.onOpenLink = { [weak self] url in self?.handle(url: url) }
        UNUserNotificationCenter.current().delegate = notificationResponder
    }

    /// Brings the daily reminder up to date with the settings and today's entries.
    func rescheduleReminders() {
        Task { await ReminderScheduler.reschedule(stores: stores) }
    }

    /// The real journal, stored in the App Group container named in Info.plist.
    static func live() throws -> AppModel {
        let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let stores = try JournalStores.live(appGroupIdentifier: groupID)
        stores.entries.discardEmptyEntries()
        let model = AppModel(stores: stores)
        // Remove items deleted more than 30 days ago, and their files.
        Task { await stores.purgeDeletedItems() }
        model.rescheduleReminders()
        return model
    }

    // MARK: Entries

    /// Creates an entry dated now (or on a given day) and opens it on the current tab,
    /// zooming out of `zoomSource` (a calendar cell) when given.
    // DECISION: the + button and the new-entry link focus the title so you can write at once.
    // An empty calendar day passes `focusTitle: false`: the page opens with the action buttons
    // showing, since you may want to add photos first.
    func createEntry(on day: DayKey? = nil, zoomSource: String? = nil, focusTitle: Bool = true) {
        let date = day.map { $0.date(atTimeOf: .now) } ?? .now
        let entry = stores.entries.create(date: date)
        if !focusTitle { unfocusedNewEntries.insert(entry.id) }
        router.push(.entry(entry.id, zoomSource: zoomSource))
    }

    func handle(url: URL) {
        switch DeepLink(url: url) {
        case .entry(let id):
            guard stores.entries.entry(id: id)?.deletedAt == nil else { return }
            isShowingSettings = false
            router.push(.entry(id))
        case .newEntry:
            isShowingSettings = false
            createEntry()
        case .onThisDay:
            isShowingSettings = false
            router.push(.onThisDay(.today))
        case nil:
            break
        }
    }

    // MARK: Editors

    func register(_ editor: EntryEditorModel) {
        editors[editor.routeEntryID] = WeakEditor(model: editor)
    }

    func unregister(_ editor: EntryEditorModel) {
        editors[editor.routeEntryID] = nil
    }

    /// Saves pending text in every open editor. Called when the app backgrounds.
    func flushEditors() {
        for box in editors.values { box.model?.flush() }
    }

    /// When an entry is popped off a stack, save it and drop it if it is still empty.
    private func routesRemoved(_ routes: [AppRoute]) {
        for case .entry(let id, _) in routes {
            if let editor = editors[id]?.model {
                editor.close()
            } else if let entry = stores.entries.entry(id: id) {
                stores.entries.discardIfEmpty(entry)
            }
        }
    }

    private struct WeakEditor {
        weak var model: EntryEditorModel?
    }
}

/// `journal://entry/<uuid>`, `journal://new` and `journal://onthisday`, for reminders, and for
/// widgets, the Watch and Shortcuts later.
enum DeepLink: Equatable {
    case entry(UUID)
    case newEntry
    case onThisDay

    init?(url: URL) {
        guard url.scheme == "journal" else { return nil }
        switch url.host() {
        case "new":
            self = .newEntry
        case "onthisday":
            self = .onThisDay
        case "entry":
            guard let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) else { return nil }
            self = .entry(id)
        default:
            return nil
        }
    }
}
