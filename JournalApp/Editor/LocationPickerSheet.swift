import MapKit
import SwiftUI

/// Tag where an entry was written: current location, or search for a place.
struct LocationPickerSheet: View {
    let current: String?
    var onPick: (Double, Double, String?) -> Void
    var onRemove: () -> Void
    var onDenied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isLocating = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        HStack {
                            Label("Current Location", systemImage: "location.fill")
                            Spacer()
                            if isLocating { ProgressView() }
                        }
                    }
                    .disabled(isLocating)
                    if let current {
                        Button(role: .destructive) {
                            onRemove()
                            dismiss()
                        } label: {
                            Label("Remove “\(current)”", systemImage: "mappin.slash")
                        }
                    }
                } footer: {
                    if let message { Text(message) }
                }

                if !results.isEmpty {
                    Section("Places") {
                        ForEach(results, id: \.self) { item in
                            Button {
                                let coordinate = item.location.coordinate
                                onPick(coordinate.latitude, coordinate.longitude, item.name)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? String(localized: "Unnamed place"))
                                        .foregroundStyle(.primary)
                                    if let address = item.address?.shortAddress {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a place")
            .task(id: query) { await search() }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func useCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        do {
            let location = try await LocationService.currentLocation()
            let name = await LocationService.placeName(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            onPick(location.coordinate.latitude, location.coordinate.longitude, name)
            dismiss()
        } catch LocationService.LocationError.denied {
            dismiss()
            onDenied()
        } catch {
            message = error.localizedDescription
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []
            return
        }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        results = (try? await LocationService.search(text)) ?? []
    }
}
