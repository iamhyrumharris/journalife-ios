import JournalCore
import SwiftUI

/// The photo collage at the top of an entry: up to four tiles, the cover first.
/// With more than four, the last tile shows "+N" and opens every photo.
public struct PhotoCollage: View {
    let items: [MediaReference]
    var onOpen: (MediaReference) -> Void
    var onShowAll: () -> Void
    var onSetCover: (MediaReference) -> Void
    var onRemove: (MediaReference) -> Void

    @State private var pendingRemoval: MediaReference?

    private static let spacing: CGFloat = 3
    private static let maxTiles = 4

    /// `items` are the entry's photos and videos, cover first.
    public init(
        items: [MediaReference],
        onOpen: @escaping (MediaReference) -> Void,
        onShowAll: @escaping () -> Void,
        onSetCover: @escaping (MediaReference) -> Void,
        onRemove: @escaping (MediaReference) -> Void
    ) {
        self.items = items
        self.onOpen = onOpen
        self.onShowAll = onShowAll
        self.onSetCover = onSetCover
        self.onRemove = onRemove
    }

    public var body: some View {
        layout
            .clipShape(.rect(cornerRadius: 12))
            .removalConfirmation($pendingRemoval, onRemove: onRemove)
    }

    // DECISION: at most four tiles (1 full, 2 side by side, 1 large + 2 stacked, 2×2), so photos
    // stay big enough to recognize; the fourth tile carries "+N" when there are more.
    @ViewBuilder
    private var layout: some View {
        let s = Self.spacing
        switch items.count {
        case 0:
            EmptyView()
        case 1:
            tile(0)
        case 2:
            HStack(spacing: s) { tile(0); tile(1) }
        case 3:
            HStack(spacing: s) {
                tile(0)
                VStack(spacing: s) { tile(1); tile(2) }
            }
        default:
            VStack(spacing: s) {
                HStack(spacing: s) { tile(0); tile(1) }
                HStack(spacing: s) { tile(2); tile(3) }
            }
        }
    }

    private var extraCount: Int { max(items.count - Self.maxTiles, 0) }

    @ViewBuilder
    private func tile(_ index: Int) -> some View {
        let item = items[index]
        let isMoreTile = index == Self.maxTiles - 1 && extraCount > 0
        Button {
            if isMoreTile { onShowAll() } else { onOpen(item) }
        } label: {
            CollageTile(reference: item)
                .overlay {
                    if isMoreTile {
                        ZStack {
                            Color.black.opacity(0.55)
                            Text(verbatim: "+\(extraCount)")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMoreTile
            ? Text("\(extraCount) more photos, show all", bundle: .module)
            : Text("Photo \(index + 1) of \(items.count)", bundle: .module))
        .contextMenu {
            if !isMoreTile {
                MediaActions(item: item, isCover: index == 0, onSetCover: onSetCover) { pendingRemoval = $0 }
            }
        }
    }
}

/// One collage tile: a large thumbnail filling its space, with a badge for videos.
private struct CollageTile: View {
    let reference: MediaReference

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { ThumbnailImage(id: reference.id, size: .large) }
            .overlay(alignment: .bottomLeading) {
                if reference.kind == .video { VideoBadge(duration: reference.duration) }
            }
            .clipped()
            .contentShape(.rect)
    }
}

struct VideoBadge: View {
    let duration: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            if let duration {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .capsule)
        .padding(6)
    }
}

/// Set as Cover and Remove, shared by the collage and the All Photos grid.
private struct MediaActions: View {
    let item: MediaReference
    let isCover: Bool
    var onSetCover: (MediaReference) -> Void
    var onRequestRemoval: (MediaReference) -> Void

    var body: some View {
        if !isCover {
            Button { onSetCover(item) } label: {
                Label { Text("Set as Cover", bundle: .module) } icon: { Image(systemName: "star") }
            }
        }
        Button(role: .destructive) { onRequestRemoval(item) } label: {
            Label { Text("Remove", bundle: .module) } icon: { Image(systemName: "trash") }
        }
    }
}

extension View {
    /// Asks before removing media from an entry. Shared by the collage, All Photos, the media
    /// strip and the full-screen viewer.
    func removalConfirmation(_ pending: Binding<MediaReference?>, onRemove: @escaping (MediaReference) -> Void) -> some View {
        confirmationDialog(
            removalTitle(for: pending.wrappedValue?.kind),
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { item in
            Button(role: .destructive) { onRemove(item) } label: { Text("Remove", bundle: .module) }
        }
    }
}

private func removalTitle(for kind: AttachmentKind?) -> Text {
    switch kind {
    case .video: Text("Remove this video from the entry?", bundle: .module)
    case .audio: Text("Remove this recording from the entry?", bundle: .module)
    case .file: Text("Remove this file from the entry?", bundle: .module)
    case .photo, nil: Text("Remove this photo from the entry?", bundle: .module)
    }
}

/// Every photo and video in an entry as a square grid. Tap to view; press and hold to
/// set the cover, move, or remove.
public struct AllPhotosGrid: View {
    let items: [MediaReference]
    let coverID: UUID?
    var onOpen: (MediaReference) -> Void
    var onMove: (MediaReference, Int) -> Void
    var onSetCover: (MediaReference) -> Void
    var onRemove: (MediaReference) -> Void

    @State private var pendingRemoval: MediaReference?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    public init(
        items: [MediaReference],
        coverID: UUID?,
        onOpen: @escaping (MediaReference) -> Void,
        onMove: @escaping (MediaReference, Int) -> Void,
        onSetCover: @escaping (MediaReference) -> Void,
        onRemove: @escaping (MediaReference) -> Void
    ) {
        self.items = items
        self.coverID = coverID
        self.onOpen = onOpen
        self.onMove = onMove
        self.onSetCover = onSetCover
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { onOpen(item) } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { ThumbnailImage(id: item.id, size: .small) }
                            .overlay(alignment: .bottomLeading) {
                                if item.kind == .video { VideoBadge(duration: item.duration) }
                            }
                            .overlay(alignment: .topTrailing) {
                                if item.id == coverID {
                                    Image(systemName: "star.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .tint)
                                        .padding(4)
                                }
                            }
                            .clipped()
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Photo \(index + 1) of \(items.count)", bundle: .module))
                    // DECISION: Move Earlier/Later in the menu instead of drag-to-reorder: it works
                    // the same with VoiceOver and doesn't fight the grid's scrolling.
                    .contextMenu {
                        if index > 0 {
                            Button { onMove(item, index - 1) } label: {
                                Label { Text("Move Earlier", bundle: .module) } icon: { Image(systemName: "arrow.left") }
                            }
                        }
                        if index < items.count - 1 {
                            Button { onMove(item, index + 1) } label: {
                                Label { Text("Move Later", bundle: .module) } icon: { Image(systemName: "arrow.right") }
                            }
                        }
                        MediaActions(item: item, isCover: item.id == coverID, onSetCover: onSetCover) { pendingRemoval = $0 }
                    }
                }
            }
        }
        .removalConfirmation($pendingRemoval, onRemove: onRemove)
    }
}
