# Journalife

A native SwiftUI journal for iPhone (iOS 26, Swift 6). Phase 1 recreates Diarium's core:
write, find and back up entries. See the spec for the full plan.

## Open and run

1. Open `JournalApp.xcodeproj` in Xcode 26.
2. Edit `Config/Identity.xcconfig` if you want a different app name, bundle ID or App Group ID.
3. Select the **JournalApp** target > **Signing & Capabilities**, pick your team. Xcode registers
   the App Group and keychain group for you.
4. Pick your iPhone and press Run.

To try it with lots of data: Settings > Data > **Generate Sample Data** (debug builds only)
adds 1,000 entries over 3 years with photos. **Delete Sample Data** removes them again.

## Tests

Product > Test (⌘U) runs the `JournalCoreTests` suite (stores, soft delete, search,
archive round-trip, zip). From Terminal: `cd Packages/JournalCore && swift test`.

## Layout

| Folder | What lives there |
| --- | --- |
| `Packages/JournalCore` | Models, stores (`EntryStore`, `TagStore`, `AttachmentStore`), media storage and thumbnails, search, archive export/import, sample data. No UI; builds for iOS, macOS and watchOS. |
| `Packages/JournalUI` | SwiftUI pieces the Mac app will reuse: entry rows, chips, rating, media strip and viewer, rich text bridge, named colors. |
| `JournalApp` | The iPhone app: tabs and navigation, Calendar, Timeline, Day list, Search, entry editor, Settings, lock. |
| `Config` | `Identity.xcconfig` (name and IDs), `Info.plist` additions, entitlements. |
| `docs` | The archive format. |

Data lives in the App Group container under `Journal/`: `Database/Journal.store` (SwiftData),
`Media/<xx>/<uuid>.<ext>` (originals) and `Thumbs/` (previews, excluded from device backup).

## Design choices to review

Unclear spots are marked with `// DECISION:` comments. Search for that tag to review them all.
The main ones:

- The body is stored as a small versioned `RichText` JSON (runs with bold, italic, underline,
  strikethrough, heading), not an encoded `AttributedString`, because SwiftUI's font attributes
  aren't `Codable`. Lists are plain-text prefixes (`• `, `1. `) that continue when you press Return.
- Archives are "stored" (uncompressed) ZIP64 files written by a small built-in zip writer, so no
  third-party package is needed. Media is already compressed.
- A brand-new empty entry is hard-deleted when you go back (it never had content to sync).
  Leftover empty entries are also cleaned up at launch.
- Importing an archive merges by UUID with last-writer-wins on `modifiedAt`. A tag with the same
  name as an existing one merges into it.

## Phase 1 status

Map and Attachments tabs show a "coming soon" screen. Audio and file attachments are Phase 2.
