import JournalCore
import SwiftUI

/// A square tile on the Attachments tab: the photo or video filling it, or a dark tile with an
/// icon and name for audio and files, with the date in the bottom-right corner.
public struct AttachmentGridTile: View {
    let item: AttachmentItem

    /// Audio and file tiles stay dark in light mode too, so the white date reads on them.
    private static let darkTile = Color(red: 0.11, green: 0.11, blue: 0.118)

    public init(_ item: AttachmentItem) {
        self.item = item
    }

    private var reference: MediaReference { item.reference }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .overlay(alignment: .bottomTrailing) { dateLabel }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch reference.kind {
        case .photo:
            // The tiles are half the screen wide, so the 256px preview would look soft.
            ThumbnailImage(id: reference.id, size: .large)
        case .video:
            ThumbnailImage(id: reference.id, size: .large)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        if let duration = reference.duration {
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(8)
                }
        case .audio:
            iconTile(systemImage: "mic.fill")
        case .file:
            iconTile(systemImage: Self.fileSymbol(for: reference.fileExtension))
        }
    }

    private func iconTile(systemImage: String) -> some View {
        ZStack {
            Self.darkTile
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.75))
        }
        .overlay(alignment: .top) {
            Text(reference.originalFilename ?? reference.fileExtension.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 8)
        }
    }

    private var dateLabel: some View {
        VStack(alignment: .trailing, spacing: -2) {
            Text(item.date.formatted(Date.FormatStyle().day(), in: item.timeZone))
                .font(.system(size: 30, weight: .bold))
            Text(item.date.formatted(Date.FormatStyle().month(.wide).year(), in: item.timeZone))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
        .padding(8)
    }

    private var accessibilityLabel: Text {
        let date = item.date.formatted(Date.FormatStyle(date: .long, time: .omitted), in: item.timeZone)
        switch reference.kind {
        case .photo: return Text("Photo, \(date)", bundle: .module)
        case .video: return Text("Video, \(date)", bundle: .module)
        case .audio: return Text("Recording \(reference.originalFilename ?? ""), \(date)", bundle: .module)
        case .file: return Text("File \(reference.originalFilename ?? ""), \(date)", bundle: .module)
        }
    }

    /// A document symbol that hints at the file's type.
    public static func fileSymbol(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "pdf": "doc.richtext.fill"
        case "zip", "gz", "tar", "rar", "7z": "doc.zipper"
        case "txt", "md", "rtf": "doc.plaintext.fill"
        case "csv", "xls", "xlsx", "numbers": "tablecells.fill"
        default: "doc.fill"
        }
    }
}
