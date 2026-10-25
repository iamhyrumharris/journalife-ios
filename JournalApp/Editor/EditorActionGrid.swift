import SwiftUI

enum EditorAction: String, CaseIterable, Identifiable {
    case photo, camera, tags, rating, audio, file, location

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .photo: "Add Photo"
        case .camera: "Take Photo"
        case .tags: "Add Tags"
        case .rating: "Add Rating"
        case .audio: "Add Audio"
        case .file: "Add File"
        case .location: "Add Location"
        }
    }

    var shortTitle: LocalizedStringResource {
        switch self {
        case .photo: "Photo"
        case .camera: "Camera"
        case .tags: "Tags"
        case .rating: "Rating"
        case .audio: "Audio"
        case .file: "File"
        case .location: "Location"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo.on.rectangle"
        case .camera: "camera"
        case .tags: "tag"
        case .rating: "star"
        case .audio: "mic"
        case .file: "paperclip"
        case .location: "mappin.and.ellipse"
        }
    }
}

/// The 2 × 3 grid of actions pinned at the bottom of the editor while the keyboard is down.
struct EditorActionGrid: View {
    var perform: (EditorAction) -> Void

    var body: some View {
        // A plain Grid lays out every tile at once. The lazy grid this replaces placed tiles
        // as they appeared, so while the keyboard went down the rows slid past each other.
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Menu {
                    Button { perform(.photo) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { perform(.camera) } label: { Label("Camera", systemImage: "camera") }
                } label: {
                    tile(.photo)
                }
                actionButton(.tags)
                actionButton(.rating)
            }
            GridRow {
                actionButton(.audio)
                actionButton(.file)
                actionButton(.location)
            }
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ action: EditorAction) -> some View {
        Button { perform(action) } label: { tile(action) }
    }

    private func tile(_ action: EditorAction) -> some View {
        VStack(spacing: 4) {
            Image(systemName: action.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(action.shortTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(action.title))
    }
}

#Preview {
    EditorActionGrid { _ in }
        .padding()
        .preferredColorScheme(.dark)
}
