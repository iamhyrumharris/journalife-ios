import JournalCore
import JournalUI
import SwiftUI

enum AttachmentFilter: String, CaseIterable, Identifiable {
    case all, photos, videos, audio, files

    var id: String { rawValue }

    var kind: AttachmentKind? {
        switch self {
        case .all: nil
        case .photos: .photo
        case .videos: .video
        case .audio: .audio
        case .files: .file
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .audio: "Audio"
        case .files: "Files"
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .all: "No attachments yet"
        case .photos: "No photos yet"
        case .videos: "No videos yet"
        case .audio: "No recordings yet"
        case .files: "No files yet"
        }
    }
}

/// Every photo, video, recording and file across all entries, newest first, in two columns.
struct AttachmentsScreen: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.attachmentsFilter) private var filter = AttachmentFilter.all
    @Namespace private var viewerZoom
    @State private var items: [AttachmentItem] = []
    @State private var viewerStart: AttachmentItem?
    @State private var isVisible = false
    @State private var isStale = true
    @State private var isLoaded = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 2)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    Button { viewerStart = item } label: {
                        AttachmentGridTile(item)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: item.id, in: viewerZoom)
                }
            }
            .padding(.horizontal, 2)
        }
        .background(JournalColors.background)
        .overlay {
            if items.isEmpty && isLoaded {
                ContentUnavailableView {
                    Label { Text(filter.emptyTitle) } icon: { Image(systemName: "square.grid.2x2") }
                } description: {
                    Text("Photos, videos, recordings and files you add to entries show up here.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { filterBar }
        .solidNavigationHeader()
        .tabRootToolbar(title: "Attachments")
        .fullScreenCover(item: $viewerStart) { start in
            MediaViewer(items: viewerItems(around: start), startAt: start.id) { reference in
                goToEntry(of: reference)
            }
            .navigationTransition(.zoom(sourceID: start.id, in: viewerZoom))
        }
        .onAppear {
            isVisible = true
            if isStale { refresh() }
        }
        .onDisappear { isVisible = false }
        // Rebuild after any change, but only while visible: no work while typing in the editor.
        .onChange(of: app.stores.changes.revision) {
            if isVisible { refresh() } else { isStale = true }
        }
        .onChange(of: filter) { refresh() }
    }

    private func refresh() {
        items = app.stores.attachments.allItems(kind: filter.kind)
        isStale = false
        isLoaded = true
    }

    // DECISION: the viewer gets the 50 items on each side of the one tapped, not the whole
    // library, so opening it stays instant with thousands of photos.
    private func viewerItems(around start: AttachmentItem) -> [MediaReference] {
        guard let index = items.firstIndex(where: { $0.id == start.id }) else { return [start.reference] }
        let lower = max(0, index - 50)
        let upper = min(items.count, index + 51)
        return items[lower..<upper].map(\.reference)
    }

    private func goToEntry(of reference: MediaReference) {
        guard let item = items.first(where: { $0.id == reference.id }) else { return }
        app.router.push(.entry(item.entryID))
    }

    /// Floating glass filter bar above the tab bar.
    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(AttachmentFilter.allCases) { option in
                Button {
                    withAnimation(.snappy) { filter = option }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .foregroundStyle(filter == option ? Color.white : Color.primary)
                        .background {
                            if filter == option {
                                Capsule().fill(.tint)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 8)
    }
}

#Preview {
    NavigationStack { AttachmentsScreen() }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
