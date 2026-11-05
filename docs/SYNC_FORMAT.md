# Sync format, version 1

Sync is local-first: each device keeps its full journal and sends changes to one provider,
iCloud or a WebDAV folder (Settings > Sync). Records use the archive's JSON shapes
(see ARCHIVE_FORMAT.md) with one extra optional field, `deletedAt`, for deletes.

## Rules

- **Identity:** every record is found by its `id` (UUID). Record keys are `entry.<UUID>` and `tag.<UUID>`.
- **Last writer wins** per record, by `modifiedAt`. Dates match when they're within a millisecond.
- **Conflicted copies:** when both sides changed an entry's title or text since the last sync,
  the losing version is saved to `Sync/Conflicts/` on the device that found the conflict.
  Settings > Sync > Conflicted Copies lists them and can restore one as a new entry.
- **Deletes** are tombstones (`deletedAt` set). A device removes a tombstone for good 30 days
  after the delete, and only once the delete has been sent and the provider's copy of its file removed.
- **Attachments** travel inside their entry (every attachment, deleted ones too), each merged by its own `modifiedAt`.
  Files go up before the record that points at them.
- **Tags** with the same name made on two devices merge into the one with the lower id.
- **Empty new entries** aren't sent until they have content.
- An entry open in the editor isn't changed by sync; the remote change waits until the editor closes.

## Device state

`<journal>/Sync/state-<provider>.json` keeps, for each record, the `modifiedAt` it had when it
last matched the provider, the provider's pull token, and which files the provider holds.
A record whose `modifiedAt` differs from its saved value is sent on the next sync.
Each provider (and each WebDAV folder) has its own file, so switching uploads everything.

## WebDAV folder

```
manifest.json
entries/<UUID>.json
tags/<UUID>.json
media/<first 2 chars of uuid>/<uuid>.<ext>
```

`manifest.json` lists every record and its `modifiedAt`:

```json
{
  "formatVersion": 1,
  "updatedAt": "2026-11-05T17:02:17.123Z",
  "records": {
    "entry.6F1C…": "2026-11-05T17:01:02.345Z",
    "tag.0A2B…": "2026-10-25T03:02:17.123Z"
  }
}
```

A pull reads the manifest and downloads only records whose value changed since this device
last saw it. A push writes the record files, then updates the manifest with `If-Match` on its
ETag, merging again if another device wrote it first. The password is stored in the Keychain.

## iCloud

The private database of container `iCloud.<bundle id>`, zone `Journal`:

| Record type | Name | Fields |
| --- | --- | --- |
| `Entry` | `entry.<UUID>` | `json` (bytes: the entry JSON), `modifiedAt` |
| `Tag` | `tag.<UUID>` | `json`, `modifiedAt` |
| `Media` | `media.<UUID>` | `file` (asset), `fileExtension`, `byteSize` |

Changes are read with the zone's change token. iCloud needs the app signed with a paid team
(`ICLOUD_SYNC_ENABLED = YES` in Config/Identity.xcconfig).
