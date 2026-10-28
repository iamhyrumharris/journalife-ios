import Foundation

/// The stored form of an entry body.
///
/// DECISION: the body is stored in this small, versioned format instead of encoding
/// SwiftUI's `AttributedString` directly. SwiftUI's font attributes are not `Codable`,
/// so bold and italic would be lost, and an archive written today should still open in
/// ten years on any platform. JournalUI converts to and from `AttributedString` for the
/// editor. Lists are stored as plain text prefixes ("• ", "1. ") inside the runs.
public struct RichText: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public struct Run: Codable, Hashable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        /// 1 for a heading, nil for body text. Room for more levels later.
        public var heading: Int?

        public init(
            text: String,
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            strikethrough: Bool = false,
            heading: Int? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.heading = heading
        }

        public func hasSameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && underline == other.underline
                && strikethrough == other.strikethrough && heading == other.heading
        }

        // Compact JSON: only write style flags that are on.
        enum CodingKeys: String, CodingKey { case text, bold = "b", italic = "i", underline = "u", strikethrough = "s", heading = "h" }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
            heading = try c.decodeIfPresent(Int.self, forKey: .heading)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            if bold { try c.encode(true, forKey: .bold) }
            if italic { try c.encode(true, forKey: .italic) }
            if underline { try c.encode(true, forKey: .underline) }
            if strikethrough { try c.encode(true, forKey: .strikethrough) }
            try c.encodeIfPresent(heading, forKey: .heading)
        }
    }

    public var version: Int
    public var runs: [Run]

    public init(runs: [Run]) {
        self.version = Self.currentVersion
        self.runs = Self.merged(runs)
    }

    public init(plain: String) {
        self.init(runs: plain.isEmpty ? [] : [Run(text: plain)])
    }

    public var plainText: String { runs.map(\.text).joined() }

    public var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> RichText {
        try JSONDecoder().decode(RichText.self, from: data)
    }

    /// Joins neighboring runs with the same style and drops empty ones.
    static func merged(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.hasSameStyle(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
