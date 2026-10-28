import JournalCore
import JournalUI
import SwiftUI
import UIKit

/// Every entry with a location as a pin, under the glass top bar and tab bar.
struct MapScreen: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.accent) private var accent = AccentChoice.blue
    @AppStorage(AppSettings.mapStyle) private var style = MapStyle.standard
    @State private var pins: [MapPin] = []
    @State private var fitRequest = 0
    @State private var clusterEntries: ClusterSelection?
    @State private var isVisible = false
    @State private var isStale = true
    @State private var isLoaded = false

    struct ClusterSelection: Identifiable {
        let id = UUID()
        let entryIDs: [UUID]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            EntryMapView(
                pins: pins,
                style: style,
                fitRequest: fitRequest,
                accent: UIColor(accent.color),
                thumbnails: app.thumbnails,
                onOpenEntry: { app.router.push(.entry($0)) },
                onShowCluster: { clusterEntries = ClusterSelection(entryIDs: $0) }
            )
            .ignoresSafeArea()

            if pins.isEmpty && isLoaded {
                emptyNotice
            }
        }
        .tabRootToolbar(title: "Map") {
            Button {
                fitRequest += 1
            } label: {
                Label("Show All Entries", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(pins.isEmpty)
            Picker(selection: $style) {
                ForEach(MapStyle.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("Map Style", systemImage: "map")
            }
            .pickerStyle(.menu)
        }
        .sheet(item: $clusterEntries) { selection in
            ClusterListSheet(entryIDs: selection.entryIDs) { id in
                clusterEntries = nil
                app.router.push(.entry(id))
            }
        }
        .onAppear {
            isVisible = true
            if isStale { refresh() }
        }
        .onDisappear { isVisible = false }
        // Rebuild after any change, but only while visible: no work while typing in the editor.
        .onChange(of: app.stores.changes.revision) {
            if isVisible { refresh() } else { isStale = true }
        }
    }

    private func refresh() {
        pins = app.stores.entries.mapPins()
        isStale = false
        isLoaded = true
    }

    private var emptyNotice: some View {
        VStack(spacing: 6) {
            Label("No places yet", systemImage: "mappin.slash")
                .font(.headline)
            Text("Add a location to an entry with its Location button, and it shows up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

/// The entries in a cluster that zooming in can't split, for example several written at home.
private struct ClusterListSheet: View {
    let entryIDs: [UUID]
    var onOpen: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [EntryRowData] = []

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button { onOpen(row.id) } label: {
                    EntryRow(row)
                }
                .buttonStyle(.plain)
                .listRowBackground(JournalColors.background)
                .alignmentGuide(.listRowSeparatorLeading) { _ in EntryRow.dateColumnWidth + 12 }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(JournalColors.background)
            .navigationTitle(Text("^[\(rows.count) entry](inflect: true)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            rows = entryIDs
                .compactMap { app.stores.entries.entry(id: $0) }
                .filter { $0.deletedAt == nil }
                .sorted { $0.entryDate > $1.entryDate }
                .map(EntryRowData.init)
        }
    }
}

#Preview {
    NavigationStack { MapScreen() }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
