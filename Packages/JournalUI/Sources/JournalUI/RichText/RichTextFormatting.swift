import JournalCore
import SwiftUI

/// Text styles offered on the editor's keyboard toolbar.
public enum RichTextStyle: String, CaseIterable, Identifiable, Sendable {
    case bold, italic, underline, strikethrough, heading

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .heading: "textformat.size.larger"
        }
    }

    public var label: LocalizedStringResource {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .heading: "Heading"
        }
    }
}

public enum ListStyle: Sendable {
    case bullet, numbered
}

/// Applies toolbar formatting to the editor's text and selection.
public enum RichTextFormatting {
    /// Toggles a style on the selection (or on what you type next, with no selection).
    /// The new state is decided once from the selection, so a mixed selection becomes uniform.
    public static func toggle(
        _ style: RichTextStyle,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection,
        context: Font.Context,
        fonts: EntryFonts = .standard
    ) {
        let current = selection.typingAttributes(in: text)
        let currentFont = current[FontKey.self]
        let resolved = currentFont?.resolve(in: context)
        switch style {
        case .bold:
            let turnOn = !(resolved?.isBold ?? false)
            text.transformAttributes(in: &selection) { container in
                guard RichTextBridge.headingLevel(container[HeadingLevelAttribute.self], font: container[FontKey.self], fonts: fonts) == nil else { return }
                container[FontKey.self] = (container[FontKey.self] ?? fonts.body).bold(turnOn)
            }
        case .italic:
            let turnOn = !(resolved?.isItalic ?? false)
            text.transformAttributes(in: &selection) { container in
                container[FontKey.self] = (container[FontKey.self] ?? fonts.body).italic(turnOn)
            }
        case .underline:
            let turnOn = current[UnderlineKey.self] == nil
            text.transformAttributes(in: &selection) { container in
                container[UnderlineKey.self] = turnOn ? .single : nil
            }
        case .strikethrough:
            let turnOn = current[StrikethroughKey.self] == nil
            text.transformAttributes(in: &selection) { container in
                container[StrikethroughKey.self] = turnOn ? .single : nil
            }
        case .heading:
            // DECISION: a heading covers every whole paragraph the cursor or selection touches,
            // as in Notes, so half a line can't be a heading.
            let turnOn = RichTextBridge.headingLevel(current[HeadingLevelAttribute.self], font: currentFont, fonts: fonts) == nil
            // What you type next at the cursor.
            text.transformAttributes(in: &selection) { container in
                container[HeadingLevelAttribute.self] = turnOn ? 1 : nil
                container[FontKey.self] = turnOn ? fonts.heading : nil
            }
            let characters = text.characters
            let (lower, upper): (AttributedString.Index, AttributedString.Index)
            switch selection.indices(in: text) {
            case .insertionPoint(let index):
                (lower, upper) = (index, index)
            case .ranges(let ranges):
                (lower, upper) = (ranges.ranges.first?.lowerBound ?? text.endIndex, ranges.ranges.last?.upperBound ?? text.endIndex)
            }
            let from = characters.distance(from: characters.startIndex, to: lower)
            let to = characters.distance(from: characters.startIndex, to: upper)
            let paragraph = Paragraphs.bounds(in: String(characters), from: from, to: to)
            guard !paragraph.isEmpty else { return }
            let start = characters.index(characters.startIndex, offsetBy: paragraph.lowerBound)
            let end = characters.index(characters.startIndex, offsetBy: paragraph.upperBound)
            text[start..<end][HeadingLevelAttribute.self] = turnOn ? 1 : nil
            text[start..<end][FontKey.self] = turnOn ? fonts.heading : nil
            // Indices don't survive the change, so put the selection back by offset.
            let newLower = text.characters.index(text.characters.startIndex, offsetBy: from)
            if from == to {
                selection = AttributedTextSelection(insertionPoint: newLower)
            } else {
                let newUpper = text.characters.index(text.characters.startIndex, offsetBy: to)
                selection = AttributedTextSelection(range: newLower..<newUpper)
            }
        }
    }

    /// Whether a style is active at the cursor, for highlighting toolbar buttons.
    public static func isActive(
        _ style: RichTextStyle,
        in text: AttributedString,
        selection: AttributedTextSelection,
        context: Font.Context,
        fonts: EntryFonts = .standard
    ) -> Bool {
        let current = selection.typingAttributes(in: text)
        let resolved = current[FontKey.self]?.resolve(in: context)
        let heading = RichTextBridge.headingLevel(current[HeadingLevelAttribute.self], font: current[FontKey.self], fonts: fonts)
        switch style {
        case .bold: return heading == nil && (resolved?.isBold ?? false)
        case .italic: return resolved?.isItalic ?? false
        case .underline: return current[UnderlineKey.self] != nil
        case .strikethrough: return current[StrikethroughKey.self] != nil
        case .heading: return heading != nil
        }
    }

    /// Starts a list item at the cursor: "• " for bullets, "1. ", "2. "... for numbers.
    ///
    /// DECISION: lists are plain-text prefixes rather than a list attribute. The iOS 26
    /// `TextEditor` has no native list support, and prefixes survive export to plain text,
    /// Markdown and any future platform unchanged. When the cursor is mid-line, the item
    /// starts on a new line. The number continues from the line above when it is numbered.
    public static func insertListItem(
        _ style: ListStyle,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection
    ) {
        let cursor: AttributedString.Index
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            cursor = index
        case .ranges(let ranges):
            cursor = ranges.ranges.first?.lowerBound ?? text.endIndex
        }

        let characters = text.characters
        let atLineStart = cursor == characters.startIndex || characters[characters.index(before: cursor)] == "\n"
        let precedingLine = previousLine(in: characters, before: cursor, atLineStart: atLineStart)

        var prefix: String
        switch style {
        case .bullet:
            prefix = "• "
        case .numbered:
            let number = precedingLine.flatMap(listNumber(of:)).map { $0 + 1 } ?? 1
            prefix = "\(number). "
        }
        if !atLineStart { prefix = "\n" + prefix }
        text.replaceSelection(&selection, withCharacters: prefix)
    }

    /// When the user presses Return on a list line, continue the list (or end it on an empty item).
    /// Returns true if it changed the text. Call from `onChange(of: text)` with the old and new text.
    public static func continueListIfNeeded(
        oldText: AttributedString,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection
    ) -> Bool {
        guard text.characters.count == oldText.characters.count + 1,
              case .insertionPoint(let cursor) = selection.indices(in: text),
              cursor > text.characters.startIndex,
              text.characters[text.characters.index(before: cursor)] == "\n"
        else { return false }

        let newlineIndex = text.characters.index(before: cursor)
        guard let line = previousLine(in: text.characters, before: newlineIndex, atLineStart: false, includeCurrent: true) else { return false }

        let isBullet = line.hasPrefix("• ")
        let number = listNumber(of: line)
        guard isBullet || number != nil else { return false }

        let marker = isBullet ? "• " : "\(number ?? 0). "
        if line == marker {
            // An empty item ends the list: remove the marker and the new line.
            let lineStart = text.characters.index(newlineIndex, offsetBy: -marker.count)
            let offset = text.characters.distance(from: text.characters.startIndex, to: lineStart)
            text.removeSubrange(lineStart..<cursor)
            // Indices are invalid after a mutation, so rebuild the cursor from its offset.
            let newCursor = text.characters.index(text.characters.startIndex, offsetBy: offset)
            selection = AttributedTextSelection(insertionPoint: newCursor)
            return true
        }
        let next = isBullet ? "• " : "\((number ?? 0) + 1). "
        text.replaceSelection(&selection, withCharacters: next)
        return true
    }

    /// After a paste, restyles the text in the journal's own fonts. Call from `onChange(of: text)`
    /// with the old and new text; returns true if it changed anything.
    ///
    /// DECISION: pasted text keeps bold, italic, underline, strikethrough and headings, and drops
    /// everything else the source app sent (its font, size and colors). It goes through the same
    /// conversion the entry is saved with, so what you see after pasting is what gets stored.
    /// Anything inserted more than one character at a time counts, which also covers dictation
    /// and autocorrect; for those the conversion changes nothing visible.
    public static func normalizePastedText(
        oldText: AttributedString,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection,
        context: Font.Context,
        fonts: EntryFonts = .standard
    ) -> Bool {
        guard text.characters.count >= oldText.characters.count + 2 else { return false }
        let normalized = RichTextBridge.attributedString(
            from: RichTextBridge.richText(from: text, context: context, fonts: fonts),
            fonts: fonts
        )
        guard normalized != text else { return false }
        // Indices don't carry over to the new string, so keep the cursor by its offset.
        let cursorOffset: Int?
        if case .insertionPoint(let index) = selection.indices(in: text) {
            cursorOffset = text.characters.distance(from: text.characters.startIndex, to: index)
        } else {
            cursorOffset = nil
        }
        text = normalized
        if let cursorOffset {
            let index = text.characters.index(text.characters.startIndex, offsetBy: min(cursorOffset, text.characters.count))
            selection = AttributedTextSelection(insertionPoint: index)
        } else {
            selection = AttributedTextSelection(insertionPoint: text.endIndex)
        }
        return true
    }

    /// The text of the line before the cursor's line (or the cursor's own line with `includeCurrent`).
    private static func previousLine(
        in characters: AttributedString.CharacterView,
        before cursor: AttributedString.Index,
        atLineStart: Bool,
        includeCurrent: Bool = false
    ) -> String? {
        var end = cursor
        if !includeCurrent {
            guard atLineStart, end > characters.startIndex else {
                // Mid-line: the "previous" line for numbering is the current line.
                var start = cursor
                while start > characters.startIndex, characters[characters.index(before: start)] != "\n" {
                    start = characters.index(before: start)
                }
                return String(characters[start..<cursor])
            }
            end = characters.index(before: end) // skip the newline
        }
        var start = end
        while start > characters.startIndex, characters[characters.index(before: start)] != "\n" {
            start = characters.index(before: start)
        }
        return String(characters[start..<end])
    }

    /// 3 for "3. Milk", nil when the line is not a numbered item.
    static func listNumber(of line: String) -> Int? {
        guard let dot = line.firstIndex(of: "."),
              line[line.index(after: dot)...].hasPrefix(" "),
              let number = Int(line[..<dot]), number > 0
        else { return nil }
        return number
    }
}
