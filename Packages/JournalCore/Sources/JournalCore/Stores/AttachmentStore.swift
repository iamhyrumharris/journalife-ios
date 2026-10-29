import Foundation
import SwiftData

@MainActor
public final class AttachmentStore {
    private let context: ModelContext
    private let changes: ChangeTracker
    private let media: MediaStorage

    init(context: ModelContext, changes: ChangeTracker, media: MediaStorage) {
        self.context = context
        self.changes = changes
        self.media = media
    }

    public func attachment(id: UUID) -> Attachment? {
        var descriptor = FetchDescriptor<Attachment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// All live attachments of live entries, newest first. Used by the Attachments tab.
    public func allMedia(kind: AttachmentKind? = nil) -> [Attachment] {
        let descriptor = FetchDescriptor<Attachment>(predicate: #Predicate { $0.deletedAt == nil })
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.entry?.deletedAt == nil && $0.entry != nil && (kind == nil || $0.kind == kind) }
            .sorted { $0.displayDate > $1.displayDate }
    }

    /// Snapshots of `allMedia` for the Attachments tab: each tile's media, entry and date.
    public func allItems(kind: AttachmentKind? = nil) -> [AttachmentItem] {
        allMedia(kind: kind).compactMap { attachment in
            guard let entry = attachment.entry else { return nil }
            return AttachmentItem(reference: attachment.reference, entryID: entry.id, date: attachment.displayDate, timeZone: entry.timeZone)
        }
    }

    /// Adds an already-imported file (see `MediaStorage.importFile`) to the end of the entry's media strip.
    @discardableResult
    public func add(_ imported: ImportedMedia, to entry: Entry) -> Attachment {
        let attachment = Attachment(id: imported.id, kind: imported.kind, fileExtension: imported.fileExtension)
        attachment.originalFilename = imported.originalFilename
        attachment.byteSize = imported.byteSize
        attachment.pixelWidth = imported.pixelWidth
        attachment.pixelHeight = imported.pixelHeight
        attachment.duration = imported.duration
        attachment.capturedAt = imported.capturedAt
        attachment.latitude = imported.latitude
        attachment.longitude = imported.longitude
        attachment.contentHash = imported.contentHash
        attachment.sortOrder = (entry.liveAttachments.map(\.sortOrder).max() ?? -1) + 1
        context.insert(attachment)
        attachment.entry = entry
        entry.modifiedAt = .now
        save(context, changes)
        return attachment
    }

    /// Soft-deletes the attachment. Its files stay on disk until the tombstone is purged.
    public func remove(_ attachment: Attachment) {
        let now = Date.now
        attachment.deletedAt = now
        attachment.modifiedAt = now
        if let entry = attachment.entry {
            if entry.coverAttachmentID == attachment.id { entry.coverAttachmentID = nil }
            entry.modifiedAt = now
        }
        save(context, changes)
    }

    /// Saves a new media strip order.
    public func reorder(_ attachments: [Attachment]) {
        let now = Date.now
        for (index, attachment) in attachments.enumerated() where attachment.sortOrder != index {
            attachment.sortOrder = index
            attachment.modifiedAt = now
        }
        attachments.first?.entry?.modifiedAt = now
        save(context, changes)
    }

    /// Moves one attachment to a new position in its entry's strip.
    public func move(_ attachment: Attachment, toIndex index: Int) {
        guard let entry = attachment.entry else { return }
        var ordered = entry.liveAttachments
        guard let from = ordered.firstIndex(where: { $0.id == attachment.id }) else { return }
        let item = ordered.remove(at: from)
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        reorder(ordered)
    }
}
