import Foundation
import SwiftData

/// Exports and imports `.journalife` archive files on a background context.
///
/// After an import, call `JournalStores.reloadAfterBackgroundChanges()` on the main actor
/// so screens refetch.
@ModelActor
public actor ArchiveService {
    /// Writes every live entry, tag and media file to a new archive at `url`.
    public func export(to url: URL, location: StorageLocation, appVersion: String? = nil) throws -> ArchiveExportSummary {
        let entries = try modelContext.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.entryDate)]
        ))
        let tags = try modelContext.fetch(FetchDescriptor<Tag>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]
        ))

        let fm = FileManager.default
        var missingFiles = 0
        var files: [(source: URL, path: String)] = []
        var entryRecords: [EntryRecord] = []
        entryRecords.reserveCapacity(entries.count)

        for entry in entries {
            var attachmentRecords: [AttachmentRecord] = []
            for attachment in entry.liveAttachments {
                let source = location.originalURL(id: attachment.id, fileExtension: attachment.fileExtension)
                var path: String? = ArchiveFormat.mediaPath(id: attachment.id, fileExtension: attachment.fileExtension)
                if fm.fileExists(atPath: source.path), let path {
                    files.append((source, path))
                } else {
                    missingFiles += 1
                    path = nil
                }
                attachmentRecords.append(AttachmentRecord(attachment, file: path))
            }
            entryRecords.append(EntryRecord(entry, attachments: attachmentRecords))
        }

        let manifest = ArchiveManifest(
            formatVersion: ArchiveFormat.formatVersion,
            exportedAt: .now,
            appVersion: appVersion,
            entryCount: entryRecords.count,
            tagCount: tags.count,
            attachmentCount: files.count
        )

        let encoder = ArchiveFormat.makeEncoder()
        let writer = try ZipWriter(url: url)
        try writer.addData(try encoder.encode(manifest), path: ArchiveFormat.manifestPath)
        try writer.addData(try encoder.encode(tags.map(TagRecord.init)), path: ArchiveFormat.tagsPath)
        try writer.addData(try encoder.encode(entryRecords), path: ArchiveFormat.entriesPath)
        for file in files {
            try writer.addFile(at: file.source, path: file.path)
        }
        try writer.finish()

        return ArchiveExportSummary(url: url, entryCount: entryRecords.count, attachmentCount: files.count, missingFiles: missingFiles)
    }

    /// Restores from an archive, merging by UUID so importing twice never duplicates.
    ///
    /// Merge rule: last writer wins per record, by `modifiedAt` (the same rule sync will use).
    /// Records only on this device are left alone.
    public func importArchive(from url: URL, location: StorageLocation) async throws -> ArchiveImportSummary {
        let reader = try ZipReader(url: url)
        let decoder = ArchiveFormat.makeDecoder()

        guard let manifestEntry = reader.entry(ArchiveFormat.manifestPath) else { throw ArchiveError.missingPart("manifest.json") }
        let manifest = try decoder.decode(ArchiveManifest.self, from: try reader.data(for: manifestEntry))
        guard manifest.formatVersion <= ArchiveFormat.formatVersion else { throw ArchiveError.newerFormat(manifest.formatVersion) }

        guard let tagsEntry = reader.entry(ArchiveFormat.tagsPath) else { throw ArchiveError.missingPart("tags.json") }
        guard let entriesEntry = reader.entry(ArchiveFormat.entriesPath) else { throw ArchiveError.missingPart("entries.json") }
        let tagRecords = try decoder.decode([TagRecord].self, from: try reader.data(for: tagsEntry))
        let entryRecords = try decoder.decode([EntryRecord].self, from: try reader.data(for: entriesEntry))

        var summary = ArchiveImportSummary()
        try location.prepareDirectories()

        // Tags
        var tagsByID: [UUID: Tag] = [:]
        for tag in try modelContext.fetch(FetchDescriptor<Tag>()) { tagsByID[tag.id] = tag }
        var tagIDMap: [UUID: UUID] = [:]
        for record in tagRecords {
            if let existing = tagsByID[record.id] {
                if record.modifiedAt > existing.modifiedAt { record.apply(to: existing) }
                tagIDMap[record.id] = existing.id
                continue
            }
            // DECISION: a tag with a different id but the same name (ignoring case) is the
            // same tag, so names stay unique. Its entries are attached to the local tag.
            let folded = SearchMatcher.fold(record.name)
            if let sameName = tagsByID.values.first(where: { $0.deletedAt == nil && SearchMatcher.fold($0.name) == folded }) {
                tagIDMap[record.id] = sameName.id
                continue
            }
            let tag = Tag(id: record.id, name: record.name, colorHex: record.colorHex, symbolName: record.symbolName, sortOrder: record.sortOrder)
            record.apply(to: tag)
            modelContext.insert(tag)
            tagsByID[tag.id] = tag
            tagIDMap[record.id] = tag.id
            summary.tagsAdded += 1
        }

        // Entries and attachments
        var entriesByID: [UUID: Entry] = [:]
        for entry in try modelContext.fetch(FetchDescriptor<Entry>()) { entriesByID[entry.id] = entry }
        var attachmentsByID: [UUID: Attachment] = [:]
        for attachment in try modelContext.fetch(FetchDescriptor<Attachment>()) { attachmentsByID[attachment.id] = attachment }

        var needsThumbnails: [MediaReference] = []
        let fm = FileManager.default

        for record in entryRecords {
            let entry: Entry
            if let existing = entriesByID[record.id] {
                guard record.modifiedAt > existing.modifiedAt else {
                    summary.entriesUnchanged += 1
                    continue
                }
                entry = existing
                summary.entriesUpdated += 1
            } else {
                entry = Entry(id: record.id, entryDate: record.entryDate)
                modelContext.insert(entry)
                entriesByID[entry.id] = entry
                summary.entriesAdded += 1
            }
            record.apply(to: entry)
            entry.tags = record.tagIDs.compactMap { tagIDMap[$0].flatMap { tagsByID[$0] } }

            for attachmentRecord in record.attachments {
                let attachment: Attachment
                if let existing = attachmentsByID[attachmentRecord.id] {
                    attachment = existing
                    if attachmentRecord.modifiedAt > existing.modifiedAt { attachmentRecord.apply(to: existing) }
                } else {
                    attachment = Attachment(id: attachmentRecord.id, kind: attachmentRecord.kind, fileExtension: attachmentRecord.fileExtension)
                    attachmentRecord.apply(to: attachment)
                    modelContext.insert(attachment)
                    attachmentsByID[attachment.id] = attachment
                    summary.attachmentsAdded += 1
                }
                attachment.entry = entry

                let destination = location.originalURL(id: attachment.id, fileExtension: attachment.fileExtension)
                if !fm.fileExists(atPath: destination.path),
                   let path = attachmentRecord.file, let zipEntry = reader.entry(path) {
                    try reader.extract(zipEntry, to: destination)
                    FileProtection.apply(to: destination)
                    summary.filesRestored += 1
                }
                if attachment.kind.isVisual, !fm.fileExists(atPath: location.thumbnailURL(id: attachment.id, size: .small).path) {
                    needsThumbnails.append(attachment.reference)
                }
            }
        }

        try modelContext.save()

        let media = MediaStorage(location: location)
        for reference in needsThumbnails {
            await media.generateThumbnails(for: reference)
        }
        return summary
    }
}

// MARK: Record conversions

extension TagRecord {
    init(_ tag: Tag) {
        self.init(id: tag.id, name: tag.name, colorHex: tag.colorHex, symbolName: tag.symbolName, sortOrder: tag.sortOrder, createdAt: tag.createdAt, modifiedAt: tag.modifiedAt)
    }

    func apply(to tag: Tag) {
        tag.name = name
        tag.colorHex = colorHex
        tag.symbolName = symbolName
        tag.sortOrder = sortOrder
        tag.createdAt = createdAt
        tag.modifiedAt = modifiedAt
        tag.deletedAt = nil
    }
}

extension AttachmentRecord {
    init(_ a: Attachment, file: String?) {
        self.init(
            id: a.id, kind: a.kind, fileExtension: a.fileExtension, originalFilename: a.originalFilename,
            byteSize: a.byteSize, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, duration: a.duration,
            capturedAt: a.capturedAt, latitude: a.latitude, longitude: a.longitude, sortOrder: a.sortOrder,
            transcript: a.transcript, contentHash: a.contentHash, createdAt: a.createdAt, modifiedAt: a.modifiedAt,
            file: file
        )
    }

    func apply(to a: Attachment) {
        a.kind = kind
        a.fileExtension = fileExtension
        a.originalFilename = originalFilename
        a.byteSize = byteSize
        a.pixelWidth = pixelWidth
        a.pixelHeight = pixelHeight
        a.duration = duration
        a.capturedAt = capturedAt
        a.latitude = latitude
        a.longitude = longitude
        a.sortOrder = sortOrder
        a.transcript = transcript
        a.contentHash = contentHash
        a.createdAt = createdAt
        a.modifiedAt = modifiedAt
        a.deletedAt = nil
    }
}

extension EntryRecord {
    init(_ e: Entry, attachments: [AttachmentRecord]) {
        self.init(
            id: e.id, entryDate: e.entryDate, timeZoneID: e.timeZoneID, title: e.title,
            body: e.bodyRich.flatMap { try? RichText.decode(from: $0) }, bodyPlain: e.bodyPlain,
            rating: e.rating, isFavorite: e.isFavorite, latitude: e.latitude, longitude: e.longitude,
            placeName: e.placeName, coverAttachmentID: e.coverAttachmentID, tagIDs: e.liveTags.map(\.id),
            attachments: attachments, source: e.source, sourceID: e.sourceID,
            createdAt: e.createdAt, modifiedAt: e.modifiedAt
        )
    }

    func apply(to e: Entry) {
        e.entryDate = entryDate
        e.timeZoneID = timeZoneID
        e.title = title
        e.bodyRich = try? (body ?? RichText(plain: bodyPlain)).encoded()
        e.bodyPlain = bodyPlain
        e.rating = rating
        e.isFavorite = isFavorite
        e.latitude = latitude
        e.longitude = longitude
        e.placeName = placeName
        e.coverAttachmentID = coverAttachmentID
        e.source = source
        e.sourceID = sourceID
        e.createdAt = createdAt
        e.modifiedAt = modifiedAt
        e.deletedAt = nil
    }
}
