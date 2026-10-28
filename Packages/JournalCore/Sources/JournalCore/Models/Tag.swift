import Foundation
import SwiftData

/// A tag shown as a colored capsule on entries. Names are unique case-insensitively,
/// enforced in `TagStore` rather than in the schema (CloudKit does not allow unique constraints).
@Model
public final class Tag {
    public var id: UUID = UUID()
    public var name: String = ""
    public var colorHex: String = "#0A84FF"
    /// SF Symbol for the chip icon.
    public var symbolName: String = "tag"
    /// Manual order in the tag picker.
    public var sortOrder: Int = 0
    public var entries: [Entry]? = []

    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now
    public var deletedAt: Date? = nil

    public init(id: UUID = UUID(), name: String, colorHex: String, symbolName: String, sortOrder: Int) {
        let now = Date.now
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.createdAt = now
        self.modifiedAt = now
    }
}

public extension Tag {
    var liveEntries: [Entry] { (entries ?? []).filter { $0.deletedAt == nil } }
}
