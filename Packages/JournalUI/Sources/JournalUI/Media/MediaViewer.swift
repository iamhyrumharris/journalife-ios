import ImageIO
import JournalCore
import SwiftUI
#if canImport(AVKit)
import AVKit
#endif

/// Full-screen viewer that swipes between an entry's media.
public struct MediaViewer: View {
    let items: [MediaReference]
    @State private var selection: UUID
    var onGoToEntry: ((MediaReference) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.storageLocation) private var location

    public init(items: [MediaReference], startAt: UUID, onGoToEntry: ((MediaReference) -> Void)? = nil) {
        self.items = items
        self._selection = State(initialValue: startAt)
        self.onGoToEntry = onGoToEntry
    }

    public var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    MediaPage(reference: item, location: location)
                        .tag(item.id)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            #endif
            .background(.black)
            .ignoresSafeArea(edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label { Text("Close", bundle: .module) } icon: { Image(systemName: "xmark") } }
                }
                if let current, let location {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: location.originalURL(id: current.id, fileExtension: current.fileExtension))
                    }
                }
                if let onGoToEntry, let current {
                    ToolbarItem(placement: Self.goToEntryPlacement) {
                        Button {
                            dismiss()
                            onGoToEntry(current)
                        } label: {
                            Text("Go to entry", bundle: .module)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var current: MediaReference? { items.first { $0.id == selection } }

    private static var goToEntryPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

private struct MediaPage: View {
    let reference: MediaReference
    let location: StorageLocation?

    var body: some View {
        if let location {
            let url = location.originalURL(id: reference.id, fileExtension: reference.fileExtension)
            switch reference.kind {
            case .photo:
                ZoomablePhoto(url: url, thumbnailID: reference.id)
            case .video:
                #if canImport(AVKit)
                VideoPage(url: url)
                #else
                FileTileContent(systemImage: "video", name: reference.originalFilename)
                #endif
            case .audio, .file:
                VStack(spacing: 16) {
                    Image(systemName: reference.kind == .audio ? "waveform" : "doc")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text(reference.originalFilename ?? url.lastPathComponent)
                        .font(.headline)
                    ShareLink(item: url) { Text("Open in…", bundle: .module) }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Color.black
        }
    }
}

/// A photo that loads a screen-sized version of the original and supports pinch to zoom.
private struct ZoomablePhoto: View {
    let url: URL
    let thumbnailID: UUID

    @State private var image: DecodedImage?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ThumbnailImage(id: thumbnailID, size: .large, placeholder: .black)
                    .scaledToFit()
            }
        }
        .scaleEffect(scale)
        .gesture(
            MagnifyGesture()
                .onChanged { scale = max(1, committedScale * $0.magnification) }
                .onEnded { _ in committedScale = scale }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy) {
                scale = scale > 1 ? 1 : 2.5
                committedScale = scale
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Photo", bundle: .module))
        .task(id: url) {
            image = await Self.load(url)
        }
    }

    /// Downsamples the original to at most 2048px with ImageIO, off the main actor.
    nonisolated static func load(_ url: URL) async -> DecodedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(DecodedImage.init)
        }.value
    }
}

#if canImport(AVKit)
private struct VideoPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}
#endif
