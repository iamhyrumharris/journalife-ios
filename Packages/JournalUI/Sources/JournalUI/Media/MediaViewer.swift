import ImageIO
import JournalCore
import QuickLook
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
                // Audio and files share a copy named after the original from their own page.
                if let current, current.kind.isVisual, let location {
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
            case .audio:
                AudioPlayerView(url: url, title: reference.originalFilename)
                    .overlay(alignment: .bottom) {
                        NamedShareButton(reference: reference, url: url)
                            .padding(.bottom, 60)
                    }
            case .file:
                FilePage(reference: reference, url: url)
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

/// A file attachment: its name and size, a Quick Look preview, and Open In.
private struct FilePage: View {
    let reference: MediaReference
    let url: URL

    @State private var previewURL: URL?
    @State private var namedURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: AttachmentGridTile.fileSymbol(for: reference.fileExtension))
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(reference.originalFilename ?? url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                Text(Int64(size).formatted(.byteCount(style: .file)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    previewURL = namedURL ?? url
                } label: {
                    Label { Text("Preview", bundle: .module) } icon: { Image(systemName: "eye") }
                }
                .buttonStyle(.borderedProminent)
                NamedShareButton(reference: reference, url: url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .quickLookPreview($previewURL)
        .task(id: url) { namedURL = await NamedFileCopy.prepare(reference: reference, original: url) }
    }
}

/// Shares a copy of the file named after the original ("Report.pdf"), not the
/// journal's internal name.
private struct NamedShareButton: View {
    let reference: MediaReference
    let url: URL

    @State private var namedURL: URL?

    var body: some View {
        ShareLink(item: namedURL ?? url) {
            Label { Text("Open in…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
        }
        .buttonStyle(.bordered)
        .task(id: url) { namedURL = await NamedFileCopy.prepare(reference: reference, original: url) }
    }
}

enum NamedFileCopy {
    /// A link (or copy) of the original in a temporary folder, under its original file name.
    nonisolated static func prepare(reference: MediaReference, original: URL) async -> URL? {
        guard let name = reference.originalFilename, !name.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let fm = FileManager.default
            let folder = URL.temporaryDirectory.appending(path: "Shared/\(reference.id.uuidString)", directoryHint: .isDirectory)
            // Keep the original's extension so other apps know what it is.
            var fileName = (name as NSString).lastPathComponent
            if !reference.fileExtension.isEmpty, (fileName as NSString).pathExtension.lowercased() != reference.fileExtension.lowercased() {
                fileName += ".\(reference.fileExtension)"
            }
            let destination = folder.appending(path: fileName)
            if fm.fileExists(atPath: destination.path) { return destination }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                do {
                    try fm.linkItem(at: original, to: destination)
                } catch {
                    try fm.copyItem(at: original, to: destination)
                }
                return destination
            } catch {
                return nil
            }
        }.value
    }
}
