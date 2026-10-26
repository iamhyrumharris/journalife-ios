import Foundation
import SwiftData

/// One journal entry.
///
/// Sync rules (see spec, Data model): stable `id`, `createdAt`/`modifiedAt` in UTC,
/// soft delete through `deletedAt`, every property optional or defaulted, and no
/// `@Attribute(.unique)`, so the store stays compatible with CloudKit later.
@Model
public final class Entry {
    public var id: UUID = UUID()
    /// The date and time the entry is "for". Drives Calendar and Timeline.
    public var entryDate: Date = Date.now
    /// Time zone where the entry was written, so its day stays right after travel.
    public var timeZoneID: String = "UTC"
    public var title: String = ""
    /// Encoded `RichText` (see `RichText.encoded()`).
    public var bodyRich: Data? = nil
    /// Plain-text copy of the body, kept in sync on save. Used for search, previews, export.
    public var bodyPlain: String = ""
    /// 1 to 5, nil when unset.
    public var rating: Int? = nil
    public var isFavorite: Bool = false
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    public var placeName: String? = nil
    /// Calendar and map photo override.
    public var coverAttachmentID: UUID? = nil

    @Relationship(inverse: \Tag.entries)
    public var tags: [Tag]? = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.entry)
    public var attachments: [Attachment]? = []

    /// "diarium" etc. for imported entries.
    public var source: String? = nil
    /// Original ID from the import, to avoid duplicate imports.
    public var sourceID: String? = nil

    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now
    public var deletedAt: Date? = nil

    public init(id: UUID = UUID(), entryDate: Date = .now, timeZone: TimeZone = .current) {
        let now = Date.now
        self.id = id
        self.entryDate = entryDate
        self.timeZoneID = timeZone.identifier
        self.createdAt = now
        self.modifiedAt = now
    }
}

public extension Entry {
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// The calendar day this entry belongs to, in the time zone it was written in.
    var dayKey: DayKey { DayKey(date: entryDate, timeZone: timeZone) }

    var isDeleted: Bool { deletedAt != nil }

    /// Attachments that are not soft-deleted, in media strip order.
    var liveAttachments: [Attachment] {
        (attachments ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// Tags that are not soft-deleted, in tag picker order.
    var liveTags: [Tag] {
        (tags ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// The photo or video shown for this entry on the calendar and map:
    /// the chosen cover, else the first photo or video in the media strip.
    var coverAttachment: Attachment? {
        let visual = liveAttachments.filter { $0.kind.isVisual }
        if let coverAttachmentID, let chosen = visual.first(where: { $0.id == coverAttachmentID }) {
            return chosen
        }
        return visual.first
    }

    /// True when the entry has nothing worth keeping: no title, body, attachments, tags,
    /// rating or location.
    var isEmptyContent: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bodyPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && liveAttachments.isEmpty
            && liveTags.isEmpty
            && rating == nil
            && !hasLocation
    }

    /// Title for list rows: the title, or the first line of the body when there is none.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return bodyPlain
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Body preview for list rows. Skips the first line when it is being used as the title.
    var previewText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = bodyPlain.split(whereSeparator: \.isNewline).map(String.init)
        let rest = trimmedTitle.isEmpty ? Array(lines.dropFirst()) : lines
        return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wordCount: Int {
        var count = 0
        let text = title + "\n" + bodyPlain
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    var richText: RichText {
        get {
            if let bodyRich, let decoded = try? RichText.decode(from: bodyRich) { return decoded }
            return RichText(plain: bodyPlain)
        }
    }
}
