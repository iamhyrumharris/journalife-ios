import JournalCore
import SwiftUI

/// A tag as a colored capsule: icon and name in the tag color.
public struct TagChip: View {
    let name: String
    let colorHex: String
    let symbolName: String

    public init(name: String, colorHex: String, symbolName: String) {
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
    }

    @MainActor
    public init(_ tag: Tag) {
        self.init(name: tag.name, colorHex: tag.colorHex, symbolName: tag.symbolName)
    }

    public var body: some View {
        let color = Color(hex: colorHex)
        Label(name, systemImage: symbolName)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: .capsule)
            .accessibilityLabel(Text("Tag \(name)", bundle: .module))
    }
}

/// A neutral capsule for rating and location.
public struct InfoChip: View {
    let label: Text
    let systemImage: String
    var tint: Color?

    public init(_ label: Text, systemImage: String, tint: Color? = nil) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Label { label } icon: { Image(systemName: systemImage) }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint ?? .primary)
            .background(Color.secondary.opacity(0.18), in: .capsule)
    }
}

/// Five stars, read-only, for chips and rows.
public struct RatingStars: View {
    let rating: Int

    public init(_ rating: Int) { self.rating = rating }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
            }
        }
        .foregroundStyle(.yellow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(rating) of 5 stars", bundle: .module))
    }
}

/// Tap a star to rate; tap the same star again to clear.
public struct RatingPicker: View {
    @Binding var rating: Int?

    public init(rating: Binding<Int?>) { _rating = rating }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rating = rating == star ? nil : star
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(star) stars", bundle: .module))
                .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: rating)
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack {
            TagChip(name: "Travel", colorHex: "#32D74B", symbolName: "airplane")
            TagChip(name: "Family", colorHex: "#FF9F0A", symbolName: "person.2")
        }
        InfoChip(Text(verbatim: "Zion National Park"), systemImage: "mappin.and.ellipse")
        RatingStars(4)
        RatingPicker(rating: .constant(3))
    }
    .padding()
}
