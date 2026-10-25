import Foundation
import SwiftData

@MainActor
public final class EntryStore {
    private let context: ModelContext
    private let changes: ChangeTracker

    init(context: ModelContext, changes: ChangeTracker) {
        self.context = context
        self.changes = changes
    }

    public enum Direction: Sendable { case previous, next }

    // MARK: Reading

    /// All live entries, newest first unless `newestFirst` is false.
    public func allEntries(newestFirst: Bool = true) -> [Entry] {
        let descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.entryDate, order: newestFirst ? .reverse : .forward)]
        )
        return fetch(descriptor)
    }

    public func count() -> Int {
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.deletedAt == nil })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// The entry with this id, including soft-deleted ones.
    public func entry(id: UUID) -> Entry? {
        var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    /// Live entries on a day, earliest first. Each entry's day is computed in its own time zone.
    public func entries(on day: DayKey) -> [Entry] {
        // Widen the fetch by a day each side to cover every time zone, then filter exactly.
        let start = day.startDate(in: .gmt).addingTimeInterval(-86_400)
        let end = start.addingTimeInterval(3 * 86_400)
        let descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.entryDate >= start && $0.entryDate < end },
            sortBy: [SortDescriptor(\.entryDate)]
        )
        return fetch(descriptor).filter { $0.dayKey == day }
    }

    /// The chronologically previous or next live entry, across all entries.
    public func adjacent(to entry: Entry, direction: Direction) -> Entry? {
        let date = entry.entryDate
        let id = entry.id
        var descriptor: FetchDescriptor<Entry>
        switch direction {
        case .previous:
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.deletedAt == nil && $0.entryDate <= date && $0.id != id },
                sortBy: [SortDescriptor(\.entryDate, order: .reverse)]
            )
        case .next:
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.deletedAt == nil && $0.entryDate >= date && $0.id != id },
                sortBy: [SortDescriptor(\.entryDate)]
            )
        }
        // DECISION: entries with exactly the same date are rare; fetch a few and skip
        // same-date entries on the wrong side by id order so arrows never loop.
        descriptor.fetchLimit = 8
        let candidates = fetch(descriptor)
        return candidates.first { candidate in
            if candidate.entryDate != date { return true }
            return direction == .next ? candidate.id.uuidString > id.uuidString : candidate.id.uuidString < id.uuidString
        }
    }

    /// One summary per day that has entries, for the calendar.
    ///
    /// Cover photo rule: the first entry of the day (by time) with a chosen cover wins;
    /// otherwise the first photo of the earliest entry that has one.
    // DECISION: the spec's rule reads "the entry's chosen cover, else the first photo of the
    // earliest entry that day". With several entries, a chosen cover on any of them beats
    // an automatic pick, since choosing a cover is a deliberate act.
    public func daySummaries() -> [DayKey: DaySummary] {
        var byDay: [DayKey: [Entry]] = [:]
        for entry in allEntries(newestFirst: false) {
            byDay[entry.dayKey, default: []].append(entry)
        }
        var result: [DayKey: DaySummary] = [:]
        result.reserveCapacity(byDay.count)
        for (day, entries) in byDay {
            let chosen = entries.lazy.compactMap { entry -> MediaReference? in
                guard let coverID = entry.coverAttachmentID else { return nil }
                return entry.liveAttachments.first { $0.id == coverID && $0.kind.isVisual }?.reference
            }.first
            let automatic = chosen ?? entries.lazy.compactMap { $0.coverAttachment?.reference }.first
            result[day] = DaySummary(entryIDs: entries.map(\.id), cover: automatic)
        }
        return result
    }

    /// The earliest entry date, for sizing the calendar.
    public func earliestEntryDate() -> Date? {
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.entryDate)]
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor).first?.entryDate
    }

    // MARK: Search

    /// Full-text and filtered search over live entries, newest first.
    public func search(_ query: SearchQuery) -> [Entry] {
        let terms = SearchMatcher.terms(from: query.text)
        return allEntries().filter { query.matchesFilters($0) && SearchMatcher.matches($0, terms: terms) }
    }

    // MARK: Writing

    /// Creates and saves a new entry. Call `discardIfEmpty` when the editor closes
    /// so a mis-tap does not leave an empty entry behind.
    @discardableResult
    public func create(date: Date = .now, timeZone: TimeZone = .current) -> Entry {
        let entry = Entry(entryDate: date, timeZone: timeZone)
        context.insert(entry)
        save(context, changes)
        return entry
    }

    /// Applies a user change, stamps `modifiedAt` and saves.
    public func update(_ entry: Entry, _ change: (Entry) -> Void) {
        change(entry)
        entry.modifiedAt = .now
        save(context, changes)
    }

    public func setBody(_ entry: Entry, richText: RichText) {
        let data = try? richText.encoded()
        let plain = richText.plainText
        guard data != entry.bodyRich || plain != entry.bodyPlain else { return }
        update(entry) {
            $0.bodyRich = data
            $0.bodyPlain = plain
        }
    }

    public func setTitle(_ entry: Entry, _ title: String) {
        guard title != entry.title else { return }
        update(entry) { $0.title = title }
    }

    public func setRating(_ entry: Entry, _ rating: Int?) {
        let clamped = rating.map { min(max($0, 1), 5) }
        update(entry) { $0.rating = clamped }
    }

    public func toggleFavorite(_ entry: Entry) {
        update(entry) { $0.isFavorite.toggle() }
    }

    public func setLocation(_ entry: Entry, latitude: Double?, longitude: Double?, placeName: String?) {
        update(entry) {
            $0.latitude = latitude
            $0.longitude = longitude
            $0.placeName = placeName
        }
    }

    public func setDate(_ entry: Entry, _ date: Date, timeZone: TimeZone? = nil) {
        update(entry) {
            $0.entryDate = date
            if let timeZone { $0.timeZoneID = timeZone.identifier }
        }
    }

    public func setTags(_ entry: Entry, _ tags: [Tag]) {
        update(entry) { $0.tags = tags }
    }

    public func setCover(_ entry: Entry, attachmentID: UUID?) {
        update(entry) { $0.coverAttachmentID = attachmentID }
    }

    /// Soft-deletes the entry and its attachments (tombstones, see spec).
    public func softDelete(_ entry: Entry) {
        let now = Date.now
        entry.deletedAt = now
        entry.modifiedAt = now
        for attachment in entry.attachments ?? [] where attachment.deletedAt == nil {
            attachment.deletedAt = now
            attachment.modifiedAt = now
        }
        save(context, changes)
    }

    /// Brings back a soft-deleted entry and the attachments deleted along with it.
    public func restore(_ entry: Entry) {
        guard let deletedAt = entry.deletedAt else { return }
        let now = Date.now
        entry.deletedAt = nil
        entry.modifiedAt = now
        for attachment in entry.attachments ?? [] where attachment.deletedAt == deletedAt {
            attachment.deletedAt = nil
            attachment.modifiedAt = now
        }
        save(context, changes)
    }

    /// Removes a brand-new entry that never got any content. Returns true if it was removed.
    ///
    /// DECISION: this is a hard delete, not a tombstone. The entry was never meaningful
    /// and (before sync exists) never left the device, so there is nothing to sync away.
    @discardableResult
    public func discardIfEmpty(_ entry: Entry) -> Bool {
        guard entry.isEmptyContent, entry.source == nil else { return false }
        context.delete(entry)
        save(context, changes)
        return true
    }

    /// Removes leftover empty entries, for example from a new entry the app was closed on.
    /// Called at launch. Returns how many were removed.
    @discardableResult
    public func discardEmptyEntries() -> Int {
        let empties = allEntries().filter { $0.isEmptyContent && $0.source == nil }
        guard !empties.isEmpty else { return 0 }
        for entry in empties { context.delete(entry) }
        save(context, changes)
        return empties.count
    }

    /// Copies the entry's text, tags, rating and location into a new entry with the same date.
    // DECISION: attachments are not duplicated, so the copy never doubles media on disk.
    @discardableResult
    public func duplicate(_ entry: Entry) -> Entry {
        let copy = Entry(entryDate: entry.entryDate, timeZone: entry.timeZone)
        copy.title = entry.title
        copy.bodyRich = entry.bodyRich
        copy.bodyPlain = entry.bodyPlain
        copy.rating = entry.rating
        copy.isFavorite = entry.isFavorite
        copy.latitude = entry.latitude
        copy.longitude = entry.longitude
        copy.placeName = entry.placeName
        context.insert(copy)
        copy.tags = entry.liveTags
        save(context, changes)
        return copy
    }

    /// Permanently removes entries and attachments whose tombstones are older than the cutoff.
    /// Returns the attachments removed so their files can be deleted.
    ///
    /// Not scheduled yet: the spec runs this only once sync exists (purge after 30 days).
    @discardableResult
    public func purgeTombstones(olderThan cutoff: Date) -> [MediaReference] {
        let entryDescriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.deletedAt != nil })
        let attachmentDescriptor = FetchDescriptor<Attachment>(predicate: #Predicate { $0.deletedAt != nil })
        var removed: [MediaReference] = []
        for attachment in fetch(attachmentDescriptor) where (attachment.deletedAt ?? .distantFuture) < cutoff {
            removed.append(attachment.reference)
            context.delete(attachment)
        }
        for entry in fetch(entryDescriptor) where (entry.deletedAt ?? .distantFuture) < cutoff {
            context.delete(entry)
        }
        save(context, changes)
        return removed
    }

    private func fetch(_ descriptor: FetchDescriptor<Entry>) -> [Entry] {
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Entry fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetch(_ descriptor: FetchDescriptor<Attachment>) -> [Attachment] {
        (try? context.fetch(descriptor)) ?? []
    }
}
