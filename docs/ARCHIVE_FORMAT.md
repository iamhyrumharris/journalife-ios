# Journal archive format, version 1

A `.journalarchive` file is a ZIP file. Entries are stored without compression and every entry
carries ZIP64 fields, so archives over 4 GB work. It opens with Finder or `unzip`.

```
manifest.json
tags.json
entries.json
Media/<first 2 chars of uuid>/<uuid>.<ext>
```

All dates are ISO 8601 strings in UTC with milliseconds, for example `2026-10-25T03:02:17.123Z`.
UUIDs are uppercase strings. Missing optional values are left out.

## manifest.json

```json
{
  "formatVersion": 1,
  "exportedAt": "2026-10-25T03:02:17.123Z",
  "appVersion": "0.1",
  "entryCount": 1000,
  "tagCount": 6,
  "attachmentCount": 750
}
```

An app refuses archives with a `formatVersion` newer than it understands.

## tags.json

An array of tags.

| Key | Type | Notes |
| --- | --- | --- |
| id | UUID | |
| name | string | Unique ignoring case |
| colorHex | string | `#RRGGBB` |
| symbolName | string | SF Symbol name |
| sortOrder | int | |
| createdAt, modifiedAt | date | |

## entries.json

An array of entries, each with its attachments inline.

| Key | Type | Notes |
| --- | --- | --- |
| id | UUID | |
| entryDate | date | The moment the entry is for |
| timeZoneID | string | IANA name, e.g. `America/Denver`. The entry's day is computed in this zone |
| title | string | May be empty |
| body | RichText? | See below |
| bodyPlain | string | Plain text of the body |
| rating | int? | 1 to 5 |
| isFavorite | bool | |
| latitude, longitude | double? | |
| placeName | string? | |
| coverAttachmentID | UUID? | |
| tagIDs | [UUID] | References `tags.json` |
| attachments | [Attachment] | See below |
| source, sourceID | string? | Where an imported entry came from |
| createdAt, modifiedAt | date | |

### RichText

```json
{ "version": 1, "runs": [ { "text": "Angels ", "b": true }, { "text": "Landing", "i": true } ] }
```

Each run has `text` plus optional flags: `b` bold, `i` italic, `u` underline, `s` strikethrough,
`h` heading level (1). Flags that are off are left out. Lists are part of the text as `• ` or `1. `
at the start of a line.

### Attachment

| Key | Type | Notes |
| --- | --- | --- |
| id | UUID | Also the media file name |
| kind | string | `photo`, `video`, `audio`, `file` |
| fileExtension | string | lowercase, e.g. `heic` |
| originalFilename | string? | |
| byteSize | int | |
| pixelWidth, pixelHeight | int? | |
| duration | double? | seconds |
| capturedAt | date? | |
| latitude, longitude | double? | |
| sortOrder | int | Order in the entry's media strip |
| transcript | string? | |
| contentHash | string? | SHA-256 hex of the file |
| createdAt, modifiedAt | date | |
| file | string? | Path of the file in the archive, absent if it was missing at export |

## Importing

Records merge by `id`. When a record exists on both sides, the one with the later `modifiedAt`
wins. Records only on the device are kept. Media files are copied only when missing, and
previews are regenerated. Deleted records are not exported.

The WebDAV sync format (Phase 3) reuses these JSON shapes.
