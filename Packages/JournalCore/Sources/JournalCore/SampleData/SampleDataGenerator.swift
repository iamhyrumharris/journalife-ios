import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Fills the journal with realistic fake entries for testing performance.
/// Debug builds offer it in Settings (1,000 entries over 3 years with photos).
@ModelActor
public actor SampleDataGenerator {
    public static let sourceName = "sample"

    public struct Options: Sendable {
        public var entryCount = 1000
        public var years = 3
        /// Share of entries that get photos.
        public var photoChance = 0.5
        public var seed: UInt64 = 42

        public init(entryCount: Int = 1000, years: Int = 3, photoChance: Double = 0.5, seed: UInt64 = 42) {
            self.entryCount = entryCount
            self.years = years
            self.photoChance = photoChance
            self.seed = seed
        }
    }

    /// Generates entries and photos. `progress` is called with the fraction done.
    @discardableResult
    public func generate(
        _ options: Options = Options(),
        location: StorageLocation,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int {
        try location.prepareDirectories()
        var rng = SplitMix64(seed: options.seed)
        let media = MediaStorage(location: location)
        let tags = makeTags()
        let span = Double(options.years) * 365 * 86_400
        let now = Date.now

        for index in 0..<options.entryCount {
            let date = now.addingTimeInterval(-Double.random(in: 0...span, using: &rng))
            let entry = Entry(entryDate: date, timeZone: .current)
            entry.source = Self.sourceName
            entry.sourceID = "sample-\(options.seed)-\(index)"
            entry.title = Double.random(in: 0...1, using: &rng) < 0.8 ? Self.title(using: &rng) : ""
            let body = Self.paragraphs(using: &rng)
            entry.bodyPlain = body
            entry.bodyRich = try? RichText(plain: body).encoded()
            if Double.random(in: 0...1, using: &rng) < 0.4 { entry.rating = Int.random(in: 1...5, using: &rng) }
            entry.isFavorite = Double.random(in: 0...1, using: &rng) < 0.08
            if Double.random(in: 0...1, using: &rng) < 0.5 {
                let place = Self.places.randomElement(using: &rng)!
                entry.latitude = place.lat + Double.random(in: -0.05...0.05, using: &rng)
                entry.longitude = place.lon + Double.random(in: -0.05...0.05, using: &rng)
                entry.placeName = place.name
            }
            modelContext.insert(entry)
            entry.tags = Array(tags.shuffled(using: &rng).prefix(Int.random(in: 0...2, using: &rng)))

            if Double.random(in: 0...1, using: &rng) < options.photoChance {
                for order in 0..<Int.random(in: 1...3, using: &rng) {
                    let hue = Double.random(in: 0...1, using: &rng)
                    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
                    try Self.writeSamplePhoto(to: url, hue: hue, seed: rng.next())
                    let imported = try await media.importFile(at: url, kind: .photo, originalFilename: "Sample.jpg", move: true)
                    let attachment = Attachment(id: imported.id, kind: .photo, fileExtension: imported.fileExtension)
                    attachment.byteSize = imported.byteSize
                    attachment.pixelWidth = imported.pixelWidth
                    attachment.pixelHeight = imported.pixelHeight
                    attachment.contentHash = imported.contentHash
                    attachment.capturedAt = date
                    attachment.sortOrder = order
                    modelContext.insert(attachment)
                    attachment.entry = entry
                }
            }

            if index % 50 == 49 {
                try modelContext.save()
                progress?(Double(index + 1) / Double(options.entryCount))
            }
        }
        try modelContext.save()
        progress?(1)
        return options.entryCount
    }

    /// Soft-deletes every generated sample entry.
    @discardableResult
    public func deleteSampleData() throws -> Int {
        let name = Self.sourceName
        let entries = try modelContext.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.source == name && $0.deletedAt == nil }))
        let now = Date.now
        for entry in entries {
            entry.deletedAt = now
            entry.modifiedAt = now
            for attachment in entry.attachments ?? [] {
                attachment.deletedAt = now
                attachment.modifiedAt = now
            }
        }
        try modelContext.save()
        return entries.count
    }

    private func makeTags() -> [Tag] {
        let specs: [(String, String, String)] = [
            ("Family", "#FF9F0A", "person.2"), ("Work", "#0A84FF", "briefcase"),
            ("Travel", "#32D74B", "airplane"), ("Gratitude", "#FFD60A", "sparkles"),
            ("Workout", "#FF453A", "figure.run"), ("Reading", "#BF5AF2", "book"),
        ]
        let existing = (try? modelContext.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return specs.enumerated().map { index, spec in
            if let match = existing.first(where: { SearchMatcher.fold($0.name) == SearchMatcher.fold(spec.0) }) { return match }
            let tag = Tag(name: spec.0, colorHex: spec.1, symbolName: spec.2, sortOrder: existing.count + index)
            modelContext.insert(tag)
            return tag
        }
    }

    // MARK: Content

    private static let places: [(name: String, lat: Double, lon: Double)] = [
        ("Salt Lake City", 40.7608, -111.8910), ("Provo", 40.2338, -111.6585),
        ("San Francisco", 37.7749, -122.4194), ("New York", 40.7128, -74.0060),
        ("London", 51.5072, -0.1276), ("Tokyo", 35.6762, 139.6503),
        ("Zion National Park", 37.2982, -113.0263), ("Moab", 38.5733, -109.5498),
    ]

    private static let titles = [
        "Morning walk", "A quiet day", "Family dinner", "Big news", "Rainy afternoon",
        "Weekend trip", "Back to work", "Thinking about the future", "Small wins",
        "Late night thoughts", "Hike with friends", "Lazy Sunday", "Birthday", "Café visit",
    ]

    private static let words = """
    today we went out early and the light was soft over the hills I made coffee and read for a while \
    before everyone woke up the kids wanted pancakes so we made a big batch work was busy but good \
    I finished the project I had been worrying about for weeks it felt great to finally ship it \
    we talked about planning a trip next summer maybe somewhere with mountains and a lake \
    the weather turned cold in the afternoon and we stayed in with a movie I am grateful for \
    small things like a warm kitchen and a long conversation with an old friend tomorrow I want to \
    get up earlier go for a run and write more consistently
    """.split(separator: " ").map(String.init)

    static func title<G: RandomNumberGenerator>(using rng: inout G) -> String {
        titles.randomElement(using: &rng)!
    }

    static func paragraphs<G: RandomNumberGenerator>(using rng: inout G) -> String {
        (0..<Int.random(in: 1...4, using: &rng)).map { _ in
            let sentences = (0..<Int.random(in: 2...5, using: &rng)).map { _ -> String in
                let count = Int.random(in: 6...16, using: &rng)
                let start = Int.random(in: 0..<(words.count - count), using: &rng)
                let sentence = words[start..<(start + count)].joined(separator: " ")
                return sentence.prefix(1).uppercased() + String(sentence.dropFirst()) + "."
            }
            return sentences.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// Draws a simple gradient "photo" so sample entries have real image files.
    static func writeSamplePhoto(to url: URL, hue: Double, seed: UInt64) throws {
        let width = 1200, height = 900
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ThumbnailGenerator.ThumbnailError.unwritable }

        let top = rgb(hue: hue, saturation: 0.55, brightness: 0.85)
        let bottom = rgb(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.35)
        let colors = [CGColor(red: top.0, green: top.1, blue: top.2, alpha: 1), CGColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        var rng = SplitMix64(seed: seed)
        for _ in 0..<6 {
            let radius = CGFloat.random(in: 60...260, using: &rng)
            let center = CGPoint(x: CGFloat.random(in: 0...CGFloat(width), using: &rng), y: CGFloat.random(in: 0...CGFloat(height), using: &rng))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat.random(in: 0.08...0.25, using: &rng)))
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        guard let image = context.makeImage() else { throw ThumbnailGenerator.ThumbnailError.unwritable }
        try ThumbnailGenerator.writeJPEG(image, to: url, quality: 0.85)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (CGFloat, CGFloat, CGFloat) {
        let h = hue * 6
        let i = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        let values: (Double, Double, Double) = switch i {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return (CGFloat(values.0), CGFloat(values.1), CGFloat(values.2))
    }
}

/// A small seeded random number generator, so sample data is the same every run.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
