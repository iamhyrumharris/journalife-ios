import JournalCore
import JournalUI
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// State and actions for the entry editor. Autosaves about a second after typing pauses,
/// when the editor closes and when the app backgrounds, so text is never lost.
@MainActor
@Observable
final class EntryEditorModel {
    /// The entry the editor was opened with. The arrows can move to other entries.
    let routeEntryID: UUID
    private(set) var entry: Entry?

    var title = "" {
        didSet { if !isLoading && title != oldValue { scheduleSave() } }
    }
    var text = AttributedString() {
        didSet { if !isLoading { scheduleSave() } }
    }
    var selection = AttributedTextSelection()

    private(set) var isImporting = false
    var errorMessage: String?
    /// Set when the first photo carries a location and the entry has none, to offer using it.
    var photoLocationOffer: PhotoLocationOffer?

    @ObservationIgnored var fontContext: Font.Context?
    @ObservationIgnored var baseFont: Font = .body
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let app: AppModel

    private var stores: JournalStores { app.stores }

    struct PhotoLocationOffer: Identifiable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
    }

    init(entryID: UUID, app: AppModel, baseFont: Font = .body) {
        self.routeEntryID = entryID
        self.app = app
        self.baseFont = baseFont
        if let entry = app.stores.entries.entry(id: entryID), entry.deletedAt == nil {
            load(entry)
        }
        app.register(self)
    }

    /// Shows an entry, replacing whatever was loaded.
    func load(_ entry: Entry) {
        isLoading = true
        defer { isLoading = false }
        self.entry = entry
        title = entry.title
        text = RichTextBridge.attributedString(from: entry.richText, baseFont: baseFont)
        selection = AttributedTextSelection()
        isDirty = false
    }

    // MARK: Saving

    func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves pending title and body changes now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let entry else { return }
        isDirty = false
        stores.entries.setTitle(entry, title)
        if let fontContext {
            stores.entries.setBody(entry, richText: RichTextBridge.richText(from: text, context: fontContext))
        } else {
            // Without a font context bold and italic can't be read; keep the words safe at least.
            stores.entries.setBody(entry, richText: RichText(plain: String(text.characters)))
        }
    }

    /// The editor was popped: save now, and drop the entry once the view is gone if it is empty.
    func close() {
        flush()
        isClosing = true
    }

    func viewDidDisappear() {
        flush()
        guard isClosing else { return }
        if let entry { stores.entries.discardIfEmpty(entry) }
        app.unregister(self)
    }

    // MARK: Navigation between entries

    func canGo(_ direction: EntryStore.Direction) -> Bool {
        guard let entry else { return false }
        return stores.entries.adjacent(to: entry, direction: direction) != nil
    }

    func go(_ direction: EntryStore.Direction) {
        guard let entry else { return }
        flush()
        guard let next = stores.entries.adjacent(to: entry, direction: direction) else { return }
        if entry.id != routeEntryID { stores.entries.discardIfEmpty(entry) }
        load(next)
    }

    // MARK: Entry actions

    func setDate(_ date: Date) {
        guard let entry else { return }
        stores.entries.setDate(entry, date)
    }

    func setRating(_ rating: Int?) {
        guard let entry else { return }
        stores.entries.setRating(entry, rating)
    }

    func toggleFavorite() {
        guard let entry else { return }
        stores.entries.toggleFavorite(entry)
    }

    func setTags(_ tags: [JournalCore.Tag]) {
        guard let entry else { return }
        stores.entries.setTags(entry, tags)
    }

    func setLocation(latitude: Double, longitude: Double, placeName: String?) {
        guard let entry else { return }
        stores.entries.setLocation(entry, latitude: latitude, longitude: longitude, placeName: placeName)
    }

    func clearLocation() {
        guard let entry else { return }
        stores.entries.setLocation(entry, latitude: nil, longitude: nil, placeName: nil)
    }

    func usePhotoLocation(_ offer: PhotoLocationOffer) async {
        let name = await LocationService.placeName(latitude: offer.latitude, longitude: offer.longitude)
        setLocation(latitude: offer.latitude, longitude: offer.longitude, placeName: name)
    }

    func delete() {
        guard let entry else { return }
        flush()
        stores.entries.softDelete(entry)
        app.router.pop()
    }

    func duplicate() {
        guard let entry else { return }
        flush()
        let copy = stores.entries.duplicate(entry)
        app.router.push(.entry(copy.id))
    }

    var shareText: String {
        guard let entry else { return "" }
        let date = entry.entryDate.formatted(Date.FormatStyle(date: .complete, time: .shortened), in: entry.timeZone)
        return [entry.title, date, String(text.characters)]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: Media

    var media: [MediaReference] { entry?.liveAttachments.map(\.reference) ?? [] }

    func importPicked(_ items: [PhotosPickerItem]) async {
        guard entry != nil, !items.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var failures = 0
        for item in items {
            do {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                guard let picked = try await item.loadTransferable(type: PickedMediaFile.self) else {
                    failures += 1
                    continue
                }
                let imported = try await stores.media.importFile(at: picked.url, kind: isVideo ? .video : .photo, move: true)
                add(imported)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            errorMessage = String(localized: "^[\(failures) item](inflect: true) couldn't be added.")
        }
    }

    func importCameraPhoto(_ data: Data) async {
        isImporting = true
        defer { isImporting = false }
        do {
            add(try await stores.media.importData(data, fileExtension: "jpg", kind: .photo, originalFilename: "Camera.jpg"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ imported: ImportedMedia) {
        guard let entry else { return }
        let isFirstVisual = !entry.liveAttachments.contains { $0.kind.isVisual }
        stores.attachments.add(imported, to: entry)
        app.thumbnails.evict(id: imported.id)
        if isFirstVisual, !entry.hasLocation, let lat = imported.latitude, let lon = imported.longitude {
            photoLocationOffer = PhotoLocationOffer(latitude: lat, longitude: lon)
        }
    }

    func remove(_ reference: MediaReference) {
        guard let attachment = stores.attachments.attachment(id: reference.id) else { return }
        stores.attachments.remove(attachment)
    }

    func move(_ reference: MediaReference, to index: Int) {
        guard let attachment = stores.attachments.attachment(id: reference.id) else { return }
        stores.attachments.move(attachment, toIndex: index)
    }

    func setCover(_ reference: MediaReference) {
        guard let entry else { return }
        stores.entries.setCover(entry, attachmentID: reference.id)
    }
}
