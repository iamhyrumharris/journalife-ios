import SwiftUI

/// How big entry text is in the editor (Settings > Appearance > Text Size).
// DECISION: Large (20 pt) is the default; the system body style (17 pt) read as too small for
// writing. Sizes are points at the default Dynamic Type size and scale with it from there.
// The size is never saved into the rich text, so every entry re-renders at the chosen size.
public enum EntryTextSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large, extraLarge

    public var id: String { rawValue }

    public var points: CGFloat {
        switch self {
        case .small: 16
        case .medium: 18
        case .large: 20
        case .extraLarge: 23
        }
    }

    public var label: LocalizedStringResource {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

/// The body and heading fonts for entry text at one size.
public struct EntryFonts: Sendable, Equatable {
    public let body: Font
    public let heading: Font

    /// `size` is the body size in points (already scaled for Dynamic Type).
    public init(size: CGFloat, serif: Bool = false) {
        let design: Font.Design = serif ? .serif : .default
        body = .system(size: size, design: design)
        // Headings stay about a third bigger than the body at every size.
        heading = .system(size: (size * 1.3).rounded(), weight: .bold, design: design)
    }

    public static let standard = EntryFonts(size: EntryTextSize.large.points)
}
