import JournalCore
import SwiftUI

/// The Timeline row: weekday over a large accent day number on the left,
/// bold title and up to four lines of preview on the right.
public struct EntryRow: View {
    let data: EntryRowData
    var highlightTerms: [String]
    var showsThumbnail: Bool?

    @Environment(\.showsRowThumbnails) private var showsRowThumbnails

    public init(_ data: EntryRowData, highlightTerms: [String] = [], showsThumbnail: Bool? = nil) {
        self.data = data
        self.highlightTerms = highlightTerms
        self.showsThumbnail = showsThumbnail
    }

    /// Width of the date column. Dividers are inset by this much so they line up with the text.
    public nonisolated static let dateColumnWidth: CGFloat = 52

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(data.date.formatted(Date.FormatStyle().weekday(.abbreviated), in: data.timeZone).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(data.date.formatted(Date.FormatStyle().day(), in: data.timeZone))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: Self.dateColumnWidth)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(highlighted(data.title.isEmpty ? String(localized: "Untitled", bundle: .module) : data.title))
                        .font(.headline)
                        .lineLimit(2)
                    if data.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel(Text("Favorite", bundle: .module))
                    }
                }
                if !data.preview.isEmpty {
                    Text(highlighted(data.preview))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsThumbnail ?? showsRowThumbnails, let thumbnail = data.thumbnail {
                ThumbnailImage(id: thumbnail.id, size: .small)
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        let date = data.date.formatted(Date.FormatStyle(date: .complete, time: .omitted), in: data.timeZone)
        return Text(verbatim: "\(date), \(data.title). \(data.preview.prefix(120))")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !highlightTerms.isEmpty else { return attributed }
        for range in SearchMatcher.matchRanges(in: text, terms: highlightTerms) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
            attributed[lower..<upper].foregroundColor = Color.primary
        }
        return attributed
    }
}

#Preview {
    List {
        EntryRow(EntryRowData(id: UUID(), date: .now, timeZone: .current, title: "Morning walk",
                              preview: "The light was soft over the hills and I made coffee before anyone woke up. It was one of those quiet mornings that make the whole week feel slower.",
                              isFavorite: true))
        EntryRow(EntryRowData(id: UUID(), date: .now.addingTimeInterval(-86_400), timeZone: .current, title: "Café visit",
                              preview: "Met an old friend at the café."), highlightTerms: ["cafe"])
    }
    .listStyle(.plain)
}
