import JournalCore
import JournalUI
import SwiftUI

/// Full-text search over titles and bodies, with filter chips and recent searches.
struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.recentSearches) private var recentData = Data()
    @State private var query = SearchQuery()
    @State private var results: [EntryRowData] = []
    @State private var tags: [JournalCore.Tag] = []
    @State private var isFieldFocused = false
    @State private var isShowingDateRange = false

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: recentData)) ?? []
    }

    private var highlightTerms: [String] { SearchMatcher.terms(from: query.text) }

    var body: some View {
        List {
            Section {
                filterChips
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(JournalColors.background)
                    .listRowSeparator(.hidden)
            }

            if query.isEmpty {
                if recentSearches.isEmpty {
                    emptyState
                        .listRowBackground(JournalColors.background)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(recentSearches, id: \.self) { recent in
                            Button {
                                query.text = recent
                            } label: {
                                Label(recent, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            .listRowBackground(JournalColors.background)
                        }
                        Button("Clear Recent Searches", role: .destructive) { recentData = Data() }
                            .listRowBackground(JournalColors.background)
                    } header: {
                        Text("Recent")
                    }
                }
            } else {
                Section {
                    ForEach(results) { row in
                        EntryListRow(row: row, highlightTerms: highlightTerms)
                    }
                } header: {
                    Text("^[\(results.count) result](inflect: true)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(JournalColors.background)
        .overlay {
            if !query.isEmpty && results.isEmpty {
                ContentUnavailableView.search(text: query.text)
            }
        }
        .searchable(text: $query.text, isPresented: $isFieldFocused, prompt: "Titles and text")
        .onSubmit(of: .search) { remember(query.text) }
        .tabRootToolbar(title: "Search")
        .onAppear {
            tags = app.stores.tags.allTags()
            isFieldFocused = true
        }
        // Opening a result remembers the search. A tap gesture on the rows did this before,
        // but it swallowed the NavigationLink tap, so results couldn't be opened.
        .onDisappear { if !query.text.isEmpty && !results.isEmpty { remember(query.text) } }
        .task(id: query) { await runSearch() }
        .onChange(of: app.stores.changes.revision) { Task { await runSearch(debounce: false) } }
        .sheet(isPresented: $isShowingDateRange) {
            DateRangeSheet(range: $query.dateRange)
        }
    }

    private func runSearch(debounce: Bool = true) async {
        if debounce {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        guard !query.isEmpty else {
            results = []
            return
        }
        results = app.stores.entries.search(query).map(EntryRowData.init)
    }

    private func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recent = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        recent.insert(trimmed, at: 0)
        recentData = (try? JSONEncoder().encode(Array(recent.prefix(10)))) ?? Data()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Search your journal", systemImage: "magnifyingglass")
        } description: {
            Text("Find words anywhere in titles and entries. Capitals and accents don't matter. Use the filters to narrow by tag, rating, date, media, location or favorites.")
        }
        .padding(.top, 40)
    }

    // MARK: Filters

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(tags) { tag in
                        Toggle(isOn: Binding(
                            get: { query.tagIDs.contains(tag.id) },
                            set: { if $0 { query.tagIDs.insert(tag.id) } else { query.tagIDs.remove(tag.id) } }
                        )) {
                            Label(tag.name, systemImage: tag.symbolName)
                        }
                    }
                    if tags.isEmpty { Text("No tags yet") }
                } label: {
                    FilterChip(title: query.tagIDs.isEmpty ? "Tags" : "Tags (\(query.tagIDs.count))", systemImage: "tag", isOn: !query.tagIDs.isEmpty)
                }

                Menu {
                    ForEach((1...5).reversed(), id: \.self) { stars in
                        Toggle(isOn: Binding(
                            get: { query.ratings.contains(stars) },
                            set: { if $0 { query.ratings.insert(stars) } else { query.ratings.remove(stars) } }
                        )) {
                            Text("^[\(stars) star](inflect: true)")
                        }
                    }
                } label: {
                    FilterChip(title: "Rating", systemImage: "star", isOn: !query.ratings.isEmpty)
                }

                Button { isShowingDateRange = true } label: {
                    FilterChip(title: "Date", systemImage: "calendar", isOn: query.dateRange != nil)
                }

                toggleChip("Photos", systemImage: "photo", isOn: $query.hasPhotos)
                toggleChip("Videos", systemImage: "video", isOn: $query.hasVideos)
                toggleChip("Audio", systemImage: "mic", isOn: $query.hasAudio)
                toggleChip("Files", systemImage: "doc", isOn: $query.hasFiles)
                toggleChip("Location", systemImage: "mappin", isOn: $query.hasLocation)
                toggleChip("Favorites", systemImage: "heart", isOn: $query.favoritesOnly)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
    }

    private func toggleChip(_ title: LocalizedStringResource, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            FilterChip(title: title, systemImage: systemImage, isOn: isOn.wrappedValue)
        }
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

private struct FilterChip: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isOn: Bool

    var body: some View {
        Label { Text(title) } icon: { Image(systemName: systemImage) }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
    }
}

private struct DateRangeSheet: View {
    @Binding var range: ClosedRange<Date>?
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(range: Binding<ClosedRange<Date>?>) {
        _range = range
        let now = Date.now
        _start = State(initialValue: range.wrappedValue?.lowerBound ?? Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now)
        _end = State(initialValue: range.wrappedValue?.upperBound ?? now)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                if range != nil {
                    Button("Clear Date Filter", role: .destructive) {
                        range = nil
                        dismiss()
                    }
                }
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        let calendar = Calendar.current
                        let lower = calendar.startOfDay(for: start)
                        let upper = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: max(start, end))) ?? end
                        range = lower...upper
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack { SearchScreen() }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
