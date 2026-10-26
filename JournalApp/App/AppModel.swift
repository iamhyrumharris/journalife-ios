import JournalCore
import JournalUI
import Observation
import SwiftUI

/// App-wide state: the stores, navigation, the lock and the shared thumbnail cache.
@MainActor
@Observable
final class AppModel {
    let stores: JournalStores
    let thumbnails: ThumbnailCache
    let router = Router()
    let lock = AppLock()
    var isShowingSettings = false

    /// Open editors, so their pending text can be saved before the app backgrounds.
    @ObservationIgnored private var editors: [UUID: WeakEditor] = [:]

    init(stores: JournalStores) {
        self.stores = stores
        self.thumbnails = ThumbnailCache(location: stores.location)
        router.onRoutesRemoved = { [weak self] routes in self?.routesRemoved(routes) }
    }

    /// The real journal, stored in the App Group container named in Info.plist.
    static func live() throws -> AppModel {
        let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let stores = try JournalStores.live(appGroupIdentifier: groupID)
        stores.entries.discardEmptyEntries()
        let model = AppModel(stores: stores)
        // Remove items deleted more than 30 days ago, and their files.
        Task { await stores.purgeDeletedItems() }
        return model
    }

    // MARK: Entries

    /// Creates an entry dated now (or on a given day) and opens it on the current tab,
    /// zooming out of `zoomSource` (a calendar cell) when given.
    func createEntry(on day: DayKey? = nil, zoomSource: String? = nil) {
        let date = day.map { $0.date(atTimeOf: .now) } ?? .now
        let entry = stores.entries.create(date: date)
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

/// `journal://entry/<uuid>` and `journal://new`, for widgets, the Watch and Shortcuts later.
enum DeepLink: Equatable {
    case entry(UUID)
    case newEntry

    init?(url: URL) {
        guard url.scheme == "journal" else { return nil }
        switch url.host() {
        case "new":
            self = .newEntry
        case "entry":
            guard let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) else { return nil }
            self = .entry(id)
        default:
            return nil
        }
    }
}
