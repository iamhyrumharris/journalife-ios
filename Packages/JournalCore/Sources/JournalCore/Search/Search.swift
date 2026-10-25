import Foundation

/// What the Search tab is looking for. Every filter is optional; an empty query matches everything.
public struct SearchQuery: Hashable, Sendable {
    public var text: String = ""
    /// Entries must have at least one of these tags.
    public var tagIDs: Set<UUID> = []
    /// Entries must have one of these ratings.
    public var ratings: Set<Int> = []
    public var dateRange: ClosedRange<Date>? = nil
    public var hasPhotos = false
    public var hasVideos = false
    public var hasAudio = false
    public var hasFiles = false
    public var hasLocation = false
    public var favoritesOnly = false

    public init(text: String = "") {
        self.text = text
    }

    public var hasFilters: Bool {
        !tagIDs.isEmpty || !ratings.isEmpty || dateRange != nil || hasPhotos || hasVideos
            || hasAudio || hasFiles || hasLocation || favoritesOnly
    }

    public var isEmpty: Bool { SearchMatcher.terms(from: text).isEmpty && !hasFilters }

    @MainActor
    func matchesFilters(_ entry: Entry) -> Bool {
        if favoritesOnly && !entry.isFavorite { return false }
        if hasLocation && !entry.hasLocation { return false }
        if !ratings.isEmpty {
            guard let rating = entry.rating, ratings.contains(rating) else { return false }
        }
        if let dateRange, !dateRange.contains(entry.entryDate) { return false }
        if !tagIDs.isEmpty && !entry.liveTags.contains(where: { tagIDs.contains($0.id) }) { return false }
        if hasPhotos || hasVideos || hasAudio || hasFiles {
            let kinds = Set(entry.liveAttachments.map(\.kind))
            if hasPhotos && !kinds.contains(.photo) { return false }
            if hasVideos && !kinds.contains(.video) { return false }
            if hasAudio && !kinds.contains(.audio) { return false }
            if hasFiles && !kinds.contains(.file) { return false }
        }
        return true
    }
}

/// Case- and accent-insensitive word matching over titles and body text.
public enum SearchMatcher {
    /// Lowercases and strips accents, so "Café" matches "cafe".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The folded words of a query. Every word must appear somewhere in the entry.
    public static func terms(from query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// True when every term appears anywhere (as a substring) in the title or body.
    @MainActor
    public static func matches(_ entry: Entry, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fold(entry.title + "\n" + entry.bodyPlain)
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Ranges in `text` that match any of the terms, for highlighting results.
    public static func matchRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}
