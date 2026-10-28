import Foundation

/// Finds whole paragraphs (lines between newlines) in text, for styles that apply per paragraph.
public enum Paragraphs {
    /// The character offsets of every paragraph that `lower..<upper` touches, without the final
    /// newline. An empty range (a cursor) gives the paragraph it sits in.
    public static func bounds(in text: String, from lower: Int, to upper: Int) -> Range<Int> {
        let characters = Array(text)
        var start = min(max(lower, 0), characters.count)
        var end = min(max(upper, start), characters.count)
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        // A selection that ends right after a newline doesn't reach into the next paragraph.
        if end > start, characters[end - 1] == "\n" { end -= 1 }
        while end < characters.count, characters[end] != "\n" { end += 1 }
        return start..<end
    }
}
