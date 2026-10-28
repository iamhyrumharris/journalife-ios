import JournalCore
import JournalUI
import SwiftUI

/// Every entry, newest first, grouped by month.
struct TimelineScreen: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.timelineNewestFirst) private var newestFirst = true
    @State private var tagFilter: UUID?
    @State private var sections: [MonthSection] = []
    @State private var tags: [JournalCore.Tag] = []
    @State private var onThisDayCount = 0
    @State private var isVisible = false
    @State private var isStale = true

    var body: some View {
        List {
            if onThisDayCount > 0 && tagFilter == nil {
                Section {
                    onThisDayRow
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        EntryListRow(row: row)
                    }
                } header: {
                    Text(section.month.monthTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .textCase(nil)
                        // Pinned month labels match the header, so rows only faintly show through them.
                        .listRowInsets(EdgeInsets())
                        .background { HeaderBackground() }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(JournalColors.background)
        .overlay {
            if sections.isEmpty && !isStale {
                if tagFilter != nil {
                    ContentUnavailableView("No entries with this tag", systemImage: "tag")
                } else {
                    ContentUnavailableView {
                        Label("No entries yet", systemImage: "book")
                    } description: {
                        Text("Tap + to write your first entry.")
                    }
                }
            }
        }
        .solidNavigationHeader()
        .tabRootToolbar(title: "Timeline") {
            Picker(selection: $newestFirst) {
                Text("Newest First").tag(true)
                Text("Oldest First").tag(false)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            Button {
                app.router.push(.onThisDay(.today))
            } label: {
                Label("On This Day", systemImage: "clock.arrow.circlepath")
            }
            Picker(selection: $tagFilter) {
                Text("All Entries").tag(UUID?.none)
                ForEach(tags) { tag in
                    Label(tag.name, systemImage: tag.symbolName).tag(UUID?.some(tag.id))
                }
            } label: {
                Label("Filter by Tag", systemImage: "line.3.horizontal.decrease")
            }
            .pickerStyle(.menu)
        }
        .onAppear {
            isVisible = true
            if isStale { refresh() }
        }
        .onDisappear { isVisible = false }
        .onChange(of: app.stores.changes.revision) {
            if isVisible { refresh() } else { isStale = true }
        }
        .onChange(of: newestFirst) { refresh() }
        .onChange(of: tagFilter) { refresh() }
    }

    private func refresh() {
        tags = app.stores.tags.allTags()
        if let tagFilter, !tags.contains(where: { $0.id == tagFilter }) { self.tagFilter = nil }
        var entries = app.stores.entries.allEntries(newestFirst: newestFirst)
        if let tagFilter { entries = entries.filter { $0.liveTags.contains { $0.id == tagFilter } } }
        sections = MonthSection.group(entries.map(EntryRowData.init))
        onThisDayCount = app.stores.entries.entriesOnThisDay(.today).count
        isStale = false
    }

    /// Entries from today's date in past years, shown above the list when there are any.
    private var onThisDayRow: some View {
        NavigationLink(value: AppRoute.onThisDay(.today)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(.headline)
                    Text("^[\(onThisDayCount) entry](inflect: true) from past years")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(JournalColors.background)
    }
}

#Preview {
    NavigationStack { TimelineScreen() }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
