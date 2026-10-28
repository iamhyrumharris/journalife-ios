import JournalCore
import SwiftUI

/// Marks heading runs in the editor's `AttributedString`.
public enum HeadingLevelAttribute: AttributedStringKey {
    public typealias Value = Int
    public static let name = "journal.headingLevel"
}

typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute
typealias UnderlineKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
typealias StrikethroughKey = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
typealias IntentKey = AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute

/// Converts between the stored `RichText` and the `AttributedString` the iOS 26 `TextEditor` edits.
public enum RichTextBridge {
    /// The heading level of a run. The editor drops custom attributes such as
    /// `HeadingLevelAttribute` from text typed after them, so the heading font also marks a heading.
    static func headingLevel(_ level: Int?, font: Font?, fonts: EntryFonts) -> Int? {
        level ?? (font == fonts.heading ? 1 : nil)
    }

    public static func attributedString(from rich: RichText, fonts: EntryFonts = .standard) -> AttributedString {
        var result = AttributedString()
        for run in rich.runs {
            var piece = AttributedString(run.text)
            if let heading = run.heading {
                piece[FontKey.self] = fonts.heading
                piece[HeadingLevelAttribute.self] = heading
            } else if run.bold || run.italic {
                piece[FontKey.self] = fonts.body.bold(run.bold).italic(run.italic)
            }
            if run.underline { piece[UnderlineKey.self] = .single }
            if run.strikethrough { piece[StrikethroughKey.self] = .single }
            result.append(piece)
        }
        return result
    }

    /// Reads styles back from the editor. `context` resolves fonts to find bold and italic,
    /// whether they came from our toolbar or from the system text formatting menu.
    public static func richText(from attributed: AttributedString, context: Font.Context, fonts: EntryFonts = .standard) -> RichText {
        var runs: [RichText.Run] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let resolved = run[FontKey.self]?.resolve(in: context)
            let intent = run[IntentKey.self] ?? []
            let heading = headingLevel(run[HeadingLevelAttribute.self], font: run[FontKey.self], fonts: fonts)
            runs.append(RichText.Run(
                text: text,
                bold: heading == nil && ((resolved?.isBold ?? false) || intent.contains(.stronglyEmphasized)),
                italic: (resolved?.isItalic ?? false) || intent.contains(.emphasized),
                underline: run[UnderlineKey.self] != nil,
                strikethrough: run[StrikethroughKey.self] != nil || intent.contains(.strikethrough),
                heading: heading
            ))
        }
        return RichText(runs: runs)
    }
}
