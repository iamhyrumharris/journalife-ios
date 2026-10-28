import JournalCore
import JournalUI
import MapKit
import SwiftUI
import UIKit

/// The map of entries, built on `MKMapView` for its native pin clustering.
// DECISION: SwiftUI's `Map` has no clustering, and clustering in code per zoom level would need
// redoing on every camera change. `MKMapView` with `MKClusterAnnotation` clusters thousands of
// pins smoothly, so the map is wrapped instead.
struct EntryMapView: UIViewRepresentable {
    let pins: [MapPin]
    let style: MapStyle
    /// Changes when the map should zoom to fit every pin again.
    let fitRequest: Int
    let accent: UIColor
    let thumbnails: ThumbnailCache
    var onOpenEntry: (UUID) -> Void
    /// A cluster that can't be split any further, for example entries written at the same place.
    var onShowCluster: ([UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.register(EntryPinView.self, forAnnotationViewWithReuseIdentifier: EntryPinView.reuseID)
        map.register(EntryClusterView.self, forAnnotationViewWithReuseIdentifier: EntryClusterView.reuseID)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.style != style {
            coordinator.style = style
            map.preferredConfiguration = style.configuration
        }
        coordinator.update(map, pins: pins)
        if coordinator.fitRequest != fitRequest || (!coordinator.hasFitted && !pins.isEmpty) {
            let animated = coordinator.hasFitted
            coordinator.fitRequest = fitRequest
            coordinator.hasFitted = true
            // After layout: fitting a map that has no size yet lands somewhere random.
            Task {
                for _ in 0..<20 where map.bounds.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                coordinator.fitAll(map, animated: animated)
            }
        }
    }

    final class Coordinator: NSObject, @preconcurrency MKMapViewDelegate {
        var parent: EntryMapView?
        var style: MapStyle?
        var fitRequest = 0
        var hasFitted = false
        private var annotations: [UUID: EntryAnnotation] = [:]

        /// Adds, moves and removes pins to match the entries, leaving unchanged ones alone.
        func update(_ map: MKMapView, pins: [MapPin]) {
            var stale = annotations
            var added: [EntryAnnotation] = []
            for pin in pins {
                if let existing = stale.removeValue(forKey: pin.entryID) {
                    if existing.pin == pin { continue }
                    map.removeAnnotation(existing)
                }
                let annotation = EntryAnnotation(pin: pin)
                annotations[pin.entryID] = annotation
                added.append(annotation)
            }
            for (id, annotation) in stale {
                annotations[id] = nil
                map.removeAnnotation(annotation)
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        func fitAll(_ map: MKMapView, animated: Bool) {
            guard !annotations.isEmpty else { return }
            var rect = MKMapRect.null
            for annotation in annotations.values {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            // A single place (or several very close together): show the neighborhood around it.
            let minimum = 20_000.0
            if rect.width < minimum || rect.height < minimum {
                rect = rect.insetBy(dx: -max(0, minimum - rect.width) / 2, dy: -max(0, minimum - rect.height) / 2)
            }
            let padding = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40)
            map.setVisibleMapRect(rect, edgePadding: padding, animated: animated)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: EntryClusterView.reuseID, for: cluster) as? EntryClusterView
                view?.configure(accent: parent?.accent ?? .systemBlue, thumbnails: parent?.thumbnails)
                return view
            }
            if let entry = annotation as? EntryAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: EntryPinView.reuseID, for: entry) as? EntryPinView
                view?.configure(accent: parent?.accent ?? .systemBlue, thumbnails: parent?.thumbnails)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            if let entry = annotation as? EntryAnnotation {
                parent?.onOpenEntry(entry.pin.entryID)
            } else if let cluster = annotation as? MKClusterAnnotation {
                open(cluster, in: mapView)
            }
        }

        /// Zooms in to a cluster, or lists its entries when zooming in can't split it.
        private func open(_ cluster: MKClusterAnnotation, in map: MKMapView) {
            let members = cluster.memberAnnotations.compactMap { $0 as? EntryAnnotation }
            var rect = MKMapRect.null
            for member in members {
                let point = MKMapPoint(member.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            // DECISION: pins within about 30 m of each other, or a map already zoomed in to street
            // level, can't be told apart by zooming, so their entries show in a list instead.
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(cluster.coordinate.latitude)
            let isTiny = max(rect.width, rect.height) < 30 * pointsPerMeter
            let isZoomedIn = map.visibleMapRect.width < 400 * pointsPerMeter
            if isTiny || isZoomedIn {
                parent?.onShowCluster(members.map(\.pin.entryID))
            } else {
                let padding = UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 60)
                map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
            }
        }
    }
}

enum MapStyle: String, CaseIterable, Identifiable {
    case standard, satellite

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .standard: "Standard"
        case .satellite: "Satellite"
        }
    }

    var configuration: MKMapConfiguration {
        switch self {
        case .standard: MKStandardMapConfiguration(elevationStyle: .realistic)
        case .satellite: MKHybridMapConfiguration(elevationStyle: .realistic)
        }
    }
}

/// One entry's pin.
final class EntryAnnotation: NSObject, MKAnnotation {
    nonisolated let pin: MapPin
    nonisolated let coordinate: CLLocationCoordinate2D

    init(pin: MapPin) {
        self.pin = pin
        self.coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
    }
}

/// A round pin: the entry's cover photo with a white border, or an accent circle with a book icon.
final class EntryPinView: MKAnnotationView {
    static let reuseID = "EntryPin"
    static let clusterID = "Entries"

    private let bubble = PhotoBubble(size: 44)

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = Self.clusterID
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        addSubview(bubble)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Entry")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var annotation: (any MKAnnotation)? {
        didSet { clusteringIdentifier = Self.clusterID }
    }

    func configure(accent: UIColor, thumbnails: ThumbnailCache?) {
        displayPriority = .defaultHigh
        bubble.show(cover: (annotation as? EntryAnnotation)?.pin.cover?.id, accent: accent, symbol: "book.closed.fill", thumbnails: thumbnails)
    }
}

/// Several nearby entries merged: a larger photo circle with the count.
final class EntryClusterView: MKAnnotationView {
    static let reuseID = "EntryCluster"

    private let bubble = PhotoBubble(size: 58)
    private let countLabel = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: 58, height: 58)
        addSubview(bubble)
        countLabel.font = .systemFont(ofSize: 13, weight: .bold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.layer.masksToBounds = true
        addSubview(countLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(accent: UIColor, thumbnails: ThumbnailCache?) {
        displayPriority = .required
        let cluster = annotation as? MKClusterAnnotation
        let members = cluster?.memberAnnotations.compactMap { $0 as? EntryAnnotation } ?? []
        // The first entry with a photo stands for the group.
        let cover = members.lazy.compactMap(\.pin.cover).first
        bubble.show(cover: cover?.id, accent: accent, symbol: "books.vertical.fill", thumbnails: thumbnails)

        let count = members.count
        countLabel.text = count.formatted()
        countLabel.backgroundColor = accent
        let size = countLabel.intrinsicContentSize
        let width = max(22, size.width + 12)
        countLabel.frame = CGRect(x: bounds.width - width + 6, y: -4, width: width, height: 22)
        countLabel.layer.cornerRadius = 11
        accessibilityLabel = String(localized: "\(count) entries")
    }
}

/// A circular image with a white border and a soft shadow, used by pins and clusters.
final class PhotoBubble: UIView {
    private let imageView = UIImageView()
    private let iconView = UIImageView()
    private var shownCover: UUID?
    private var loadTask: Task<Void, Never>?

    init(size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        layer.cornerRadius = size / 2
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)

        imageView.frame = bounds.insetBy(dx: 2, dy: 2)
        imageView.layer.cornerRadius = imageView.bounds.width / 2
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)

        iconView.frame = bounds.insetBy(dx: size * 0.28, dy: size * 0.28)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(cover: UUID?, accent: UIColor, symbol: String, thumbnails: ThumbnailCache?) {
        loadTask?.cancel()
        shownCover = cover
        backgroundColor = accent
        guard let cover else {
            imageView.image = nil
            iconView.image = UIImage(systemName: symbol)
            iconView.isHidden = false
            return
        }
        iconView.isHidden = true
        if let cached = thumbnails?.cachedImage(id: cover, size: .small) {
            imageView.image = UIImage(cgImage: cached.cgImage)
            return
        }
        imageView.image = nil
        loadTask = Task { [weak self] in
            guard let image = await thumbnails?.image(id: cover, size: .small) else { return }
            guard let self, !Task.isCancelled, self.shownCover == cover else { return }
            self.imageView.image = UIImage(cgImage: image.cgImage)
        }
    }
}
