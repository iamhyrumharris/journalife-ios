import Foundation
import SwiftData

@MainActor
public final class TagStore {
    private let context: ModelContext
    private let changes: ChangeTracker

    init(context: ModelContext, changes: ChangeTracker) {
        self.context = context
        self.changes = changes
    }

    /// Default colors offered when creating a tag.
    public static let palette = [
        "#FF453A", "#FF9F0A", "#FFD60A", "#32D74B", "#64D2FF",
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#AC8E68", "#8E8E93",
    ]

    /// SF Symbols offered for tag icons.
    public static let symbols = [
        "tag", "star", "heart", "house", "briefcase", "airplane", "car", "figure.walk",
        "figure.run", "dumbbell", "fork.knife", "cup.and.saucer", "book", "music.note",
        "camera", "gamecontroller", "leaf", "sun.max", "moon", "cloud.rain", "snowflake",
        "pawprint", "person.2", "gift", "graduationcap", "cross.case", "bed.double",
        "cart", "dollarsign.circle", "sparkles", "flag", "mappin",
    ]

    public func allTags() -> [Tag] {
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    public func tag(id: UUID) -> Tag? {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The live tag with this name, ignoring case and accents.
    public func tag(named name: String) -> Tag? {
        let folded = SearchMatcher.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return allTags().first { SearchMatcher.fold($0.name) == folded }
    }

    /// Creates a tag, or returns the existing one if the name is already used (case-insensitive).
    @discardableResult
    public func create(name: String, colorHex: String? = nil, symbolName: String = "tag") -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = tag(named: trimmed) { return existing }
        let existing = allTags()
        let color = colorHex ?? Self.palette[existing.count % Self.palette.count]
        let tag = Tag(name: trimmed, colorHex: color, symbolName: symbolName, sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(tag)
        save(context, changes)
        return tag
    }

    public enum RenameResult: Equatable, Sendable { case renamed, nameTaken, emptyName }

    public func rename(_ tag: Tag, to name: String) -> RenameResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyName }
        if let other = self.tag(named: trimmed), other.id != tag.id { return .nameTaken }
        update(tag) { $0.name = trimmed }
        return .renamed
    }

    public func update(_ tag: Tag, _ change: (Tag) -> Void) {
        change(tag)
        tag.modifiedAt = .now
        save(context, changes)
    }

    /// Moves every entry from `source` to `target`, then deletes `source`.
    public func merge(_ source: Tag, into target: Tag) {
        guard source.id != target.id else { return }
        let now = Date.now
        for entry in source.liveEntries {
            var tags = entry.tags ?? []
            tags.removeAll { $0.id == source.id }
            if !tags.contains(where: { $0.id == target.id }) { tags.append(target) }
            entry.tags = tags
            entry.modifiedAt = now
        }
        source.deletedAt = now
        source.modifiedAt = now
        target.modifiedAt = now
        save(context, changes)
    }

    /// Soft-deletes the tag. Entries keep the link, but deleted tags are hidden everywhere.
    // DECISION: links are kept (not removed) so a tag deleted by mistake can come back
    // with its entries, and so sync can resolve a delete on one device cleanly.
    public func softDelete(_ tag: Tag) {
        let now = Date.now
        tag.deletedAt = now
        tag.modifiedAt = now
        save(context, changes)
    }

    /// Saves a new manual order.
    public func reorder(_ tags: [Tag]) {
        let now = Date.now
        for (index, tag) in tags.enumerated() where tag.sortOrder != index {
            tag.sortOrder = index
            tag.modifiedAt = now
        }
        save(context, changes)
    }

    /// Tags that are on at least one live entry, most used first (then in the manual order).
    public func mostUsedTags(limit: Int = 12) -> [Tag] {
        let counted = allTags().enumerated().map { (offset: $0.offset, tag: $0.element, uses: usageCount($0.element)) }
        return counted
            .filter { $0.uses > 0 }
            .sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.offset < $1.offset }
            .prefix(limit)
            .map(\.tag)
    }

    /// How many live entries use the tag.
    public func usageCount(_ tag: Tag) -> Int { tag.liveEntries.count }
}
