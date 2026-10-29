import Foundation

/// One entry on the map: where it is and the photo its pin shows. Safe to pass across actors.
public struct MapPin: Hashable, Sendable, Identifiable {
    public let entryID: UUID
    public let latitude: Double
    public let longitude: Double
    /// The entry's cover photo or video, if it has one.
    public let cover: MediaReference?

    public var id: UUID { entryID }

    public init(entryID: UUID, latitude: Double, longitude: Double, cover: MediaReference?) {
        self.entryID = entryID
        self.latitude = latitude
        self.longitude = longitude
        self.cover = cover
    }
}

/// One tile on the Attachments tab: the media, the entry it belongs to, and the date it shows.
public struct AttachmentItem: Hashable, Sendable, Identifiable {
    public let reference: MediaReference
    public let entryID: UUID
    /// When the media was captured, else the entry's date.
    public let date: Date
    /// The entry's time zone, so the tile shows the day it was written on.
    public let timeZone: TimeZone

    public var id: UUID { reference.id }

    public init(reference: MediaReference, entryID: UUID, date: Date, timeZone: TimeZone) {
        self.reference = reference
        self.entryID = entryID
        self.date = date
        self.timeZone = timeZone
    }
}
