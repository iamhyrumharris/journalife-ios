import CoreLocation
import MapKit

/// Current location and place names, asking for permission only when first needed.
@MainActor
enum LocationService {
    enum LocationError: Error, LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: String(localized: "Location access is off for this app. You can turn it on in Settings.")
            case .unavailable: String(localized: "Your location couldn't be found right now.")
            }
        }
    }

    private static let manager = CLLocationManager()

    static func currentLocation() async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally { throw LocationError.denied }
            if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 200 {
                return location
            }
        }
        throw LocationError.unavailable
    }

    /// A short, human name for a coordinate ("Zion National Park", "Provo").
    /// Nonisolated so the non-Sendable request never leaves the context it was made in.
    @concurrent nonisolated static func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return item.name ?? item.address?.shortAddress
    }

    static func search(_ query: String, near region: MKCoordinateRegion? = nil) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        return try await MKLocalSearch(request: request).start().mapItems
    }
}
