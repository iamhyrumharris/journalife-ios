import JournalCore
import SwiftUI

/// Shows a cached thumbnail, filling its frame. Loads off the main actor and never
/// touches the full-size original.
public struct ThumbnailImage: View {
    let id: UUID
    let size: ThumbnailSize
    var placeholder: Color

    @Environment(\.thumbnailCache) private var cache
    @State private var loaded: Loaded?

    private struct Loaded {
        let id: UUID
        let image: DecodedImage
    }

    public init(id: UUID, size: ThumbnailSize = .small, placeholder: Color = JournalColors.emptyDay) {
        self.id = id
        self.size = size
        self.placeholder = placeholder
    }

    public var body: some View {
        // Read the cache synchronously first so scrolling back never flashes a placeholder.
        // A recycled view only trusts `loaded` when it is for the current id.
        let shown = (loaded?.id == id ? loaded?.image : nil) ?? cache?.cachedImage(id: id, size: size)
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let shown {
                    Image(decorative: shown.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: id) {
                guard cache?.cachedImage(id: id, size: size) == nil,
                      let image = await cache?.image(id: id, size: size) else { return }
                loaded = Loaded(id: id, image: image)
            }
    }
}

/// A square media tile: photo or video thumbnail, or an icon for audio and files.
public struct MediaTile: View {
    let reference: MediaReference

    public init(_ reference: MediaReference) {
        self.reference = reference
    }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                switch reference.kind {
                case .photo:
                    ThumbnailImage(id: reference.id)
                case .video:
                    ThumbnailImage(id: reference.id)
                        .overlay(alignment: .bottomTrailing) {
                            if let duration = reference.duration {
                                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                                    .padding(4)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(5)
                        }
                case .audio:
                    FileTileContent(systemImage: "mic.fill", name: reference.originalFilename)
                case .file:
                    FileTileContent(systemImage: "doc.fill", name: reference.originalFilename)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        switch reference.kind {
        case .photo: Text("Photo", bundle: .module)
        case .video: Text("Video", bundle: .module)
        case .audio: Text("Audio \(reference.originalFilename ?? "")", bundle: .module)
        case .file: Text("File \(reference.originalFilename ?? "")", bundle: .module)
        }
    }
}

struct FileTileContent: View {
    let systemImage: String
    let name: String?

    var body: some View {
        ZStack {
            JournalColors.card
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if let name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}
