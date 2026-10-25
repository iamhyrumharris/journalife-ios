import Foundation
import Observation
import SwiftData

/// Counts saved changes so views can refresh when anything in the journal changes.
@MainActor
@Observable
public final class ChangeTracker {
    public private(set) var revision = 0

    public init() {}

    public func bump() { revision &+= 1 }
}

/// The repository layer. Views and view models go through these stores and never touch
/// `ModelContext` directly, so storage can be wrapped for sync later.
@MainActor
public final class JournalStores {
    public let container: ModelContainer
    public let context: ModelContext
    public let location: StorageLocation
    public let changes: ChangeTracker
    public let media: MediaStorage
    public let entries: EntryStore
    public let tags: TagStore
    public let attachments: AttachmentStore

    public init(container: ModelContainer, location: StorageLocation) {
        self.container = container
        self.context = container.mainContext
        self.location = location
        let changes = ChangeTracker()
        self.changes = changes
        let media = MediaStorage(location: location)
        self.media = media
        self.entries = EntryStore(context: context, changes: changes)
        self.tags = TagStore(context: context, changes: changes)
        self.attachments = AttachmentStore(context: context, changes: changes, media: media)
    }

    /// The real on-disk journal in the App Group container.
    public static func live(appGroupIdentifier: String?) throws -> JournalStores {
        let location = StorageLocation.appGroup(appGroupIdentifier)
        let container = try JournalPersistence.makeContainer(location: location)
        return JournalStores(container: container, location: location)
    }

    /// An in-memory journal with files in a temporary folder, for tests and previews.
    public static func inMemory() throws -> JournalStores {
        let location = StorageLocation.temporary()
        try location.prepareDirectories()
        let container = try JournalPersistence.makeInMemoryContainer()
        return JournalStores(container: container, location: location)
    }

    /// How long deleted items are kept before they are removed for good.
    public static let tombstoneLifetime: TimeInterval = 30 * 86_400

    /// Permanently removes items deleted more than 30 days ago (and deleted sample data
    /// right away), along with their media files and previews. Run at launch.
    @discardableResult
    public func purgeDeletedItems(now: Date = .now) async -> Int {
        let removed = entries.purgeTombstones(olderThan: now.addingTimeInterval(-Self.tombstoneLifetime))
        for reference in removed {
            await media.removeFiles(for: reference)
        }
        return removed.count
    }

    /// Call after work done in another context (archive import, sample data) so views refetch.
    public func reloadAfterBackgroundChanges() {
        changes.bump()
    }
}

@MainActor
func save(_ context: ModelContext, _ changes: ChangeTracker) {
    do {
        if context.hasChanges { try context.save() }
    } catch {
        logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
    }
    changes.bump()
}
