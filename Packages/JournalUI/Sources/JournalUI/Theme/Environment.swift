import JournalCore
import SwiftUI

public extension EnvironmentValues {
    /// The shared thumbnail cache. Set once at the app root.
    @Entry var thumbnailCache: ThumbnailCache? = nil
    /// Where media files live, for viewers that load originals.
    @Entry var storageLocation: StorageLocation? = nil
    /// Show photo thumbnails on timeline rows (Settings, default off).
    @Entry var showsRowThumbnails: Bool = false
    /// Use New York (serif) for entry body text.
    @Entry var usesSerifBody: Bool = false
}
