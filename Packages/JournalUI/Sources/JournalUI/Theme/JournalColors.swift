import SwiftUI

/// Every app color, defined once. Values live in Colors.xcassets with light and dark variants.
public enum JournalColors {
    /// True black in dark mode, system grouped background in light mode.
    public static let background = Color("JournalBackground", bundle: .module)
    /// Rows and cards (#1C1C1E in dark mode).
    public static let card = Color("JournalCard", bundle: .module)
    /// Calendar days without entries.
    public static let emptyDay = Color("JournalEmptyDay", bundle: .module)
    public static let divider = Color("JournalDivider", bundle: .module)
    /// The small count badge on calendar cells.
    public static let badge = Color("JournalBadge", bundle: .module)
}

/// Accent color choices offered in Settings > Appearance.
public enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, gray

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .gray: .gray
        }
    }

    public var name: LocalizedStringResource {
        switch self {
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .gray: "Gray"
        }
    }
}

public extension Color {
    /// Parses "#RRGGBB" or "RRGGBB". Falls back to gray for anything else.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
