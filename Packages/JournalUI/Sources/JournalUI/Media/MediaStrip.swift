import JournalCore
import SwiftUI

/// The editor's horizontal strip of square media thumbnails.
/// Long-press a tile to move it, make it the cover, or remove it.
public struct MediaStrip: View {
    let items: [MediaReference]
    let coverID: UUID?
    var onOpen: (MediaReference) -> Void
    var onMove: (MediaReference, Int) -> Void
    var onSetCover: (MediaReference) -> Void
    var onRemove: (MediaReference) -> Void

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
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { onOpen(item) } label: {
                        MediaTile(item)
                            .frame(width: 84, height: 84)
                            .overlay(alignment: .topTrailing) {
                                if item.id == coverID {
                                    Image(systemName: "star.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .tint)
                                        .padding(4)
                                        .accessibilityLabel(Text("Cover photo", bundle: .module))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    // DECISION: long-press opens a menu (move earlier/later, cover, remove)
                    // instead of drag-to-reorder: it works the same with VoiceOver and on Mac.
                    .contextMenu {
                        if index > 0 {
                            Button { onMove(item, index - 1) } label: { Label { Text("Move Earlier", bundle: .module) } icon: { Image(systemName: "arrow.left") } }
                        }
                        if index < items.count - 1 {
                            Button { onMove(item, index + 1) } label: { Label { Text("Move Later", bundle: .module) } icon: { Image(systemName: "arrow.right") } }
                        }
                        if item.kind.isVisual {
                            Button { onSetCover(item) } label: { Label { Text("Set as Cover", bundle: .module) } icon: { Image(systemName: "star") } }
                        }
                        Button(role: .destructive) { onRemove(item) } label: { Label { Text("Remove", bundle: .module) } icon: { Image(systemName: "trash") } }
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .frame(height: 84)
    }
}
