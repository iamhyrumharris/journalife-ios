import JournalCore
import JournalUI
import SwiftUI

/// Pick tags for an entry: search, toggle existing tags, or create a new one.
struct TagPickerSheet: View {
    var onChange: ([JournalCore.Tag]) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID>
    @State private var query = ""
    @State private var tags: [JournalCore.Tag] = []
    @State private var newTagName: String?

    init(selected: [JournalCore.Tag], onChange: @escaping ([JournalCore.Tag]) -> Void) {
        _selectedIDs = State(initialValue: Set(selected.map(\.id)))
        self.onChange = onChange
    }

    private var filtered: [JournalCore.Tag] {
        let terms = SearchMatcher.terms(from: query)
        guard !terms.isEmpty else { return tags }
        return tags.filter { tag in terms.allSatisfy { SearchMatcher.fold(tag.name).contains($0) } }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if !trimmedQuery.isEmpty && app.stores.tags.tag(named: trimmedQuery) == nil {
                    Button {
                        newTagName = trimmedQuery
                    } label: {
                        Label("Create “\(trimmedQuery)”", systemImage: "plus.circle.fill")
                    }
                }
                ForEach(filtered) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        HStack {
                            TagChip(tag)
                            Spacer()
                            if selectedIDs.contains(tag.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .accessibilityAddTraits(selectedIDs.contains(tag.id) ? .isSelected : [])
                }
            }
            .overlay {
                if tags.isEmpty && trimmedQuery.isEmpty {
                    ContentUnavailableView {
                        Label("No tags yet", systemImage: "tag")
                    } description: {
                        Text("Type a name above to create your first tag.")
                    } actions: {
                        Button("New Tag") { newTagName = "" }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or create a tag")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { newTagName = "" } label: { Label("New Tag", systemImage: "plus") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
            .sheet(item: Binding(get: { newTagName.map(NewTagName.init) }, set: { newTagName = $0?.name })) { item in
                TagFormSheet(title: "New Tag", name: item.name, colorHex: nil, symbolName: "tag") { name, color, symbol in
                    let tag = app.stores.tags.create(name: name, colorHex: color, symbolName: symbol)
                    query = ""
                    refresh()
                    if !selectedIDs.contains(tag.id) { toggle(tag) }
                    return nil
                }
            }
        }
        .onAppear(perform: refresh)
        .presentationDetents([.medium, .large])
    }

    private func refresh() {
        tags = app.stores.tags.allTags()
    }

    private func toggle(_ tag: JournalCore.Tag) {
        if selectedIDs.contains(tag.id) {
            selectedIDs.remove(tag.id)
        } else {
            selectedIDs.insert(tag.id)
        }
        onChange(tags.filter { selectedIDs.contains($0.id) })
    }

    private struct NewTagName: Identifiable {
        let name: String
        var id: String { "new" }
    }
}

/// Name, color and icon for a tag. Used to create and to edit.
struct TagFormSheet: View {
    let title: LocalizedStringResource
    @State var name: String
    @State var colorHex: String
    @State var symbolName: String
    /// Returns an error message to show, or nil when saved.
    var onSave: (String, String, String) -> LocalizedStringResource?

    @Environment(\.dismiss) private var dismiss
    @State private var error: LocalizedStringResource?

    init(title: LocalizedStringResource, name: String, colorHex: String?, symbolName: String,
         onSave: @escaping (String, String, String) -> LocalizedStringResource?) {
        self.title = title
        _name = State(initialValue: name)
        _colorHex = State(initialValue: colorHex ?? TagStore.palette.randomElement() ?? "#0A84FF")
        _symbolName = State(initialValue: symbolName)
        self.onSave = onSave
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    HStack {
                        Spacer()
                        TagChip(name: name.isEmpty ? String(localized: "Preview") : name, colorHex: colorHex, symbolName: symbolName)
                        Spacer()
                    }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Color") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(TagStore.palette, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 32, height: 32)
                                    .overlay { if hex == colorHex { Circle().strokeBorder(.primary, lineWidth: 3) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: hex))
                            .accessibilityAddTraits(hex == colorHex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Icon") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(TagStore.symbols, id: \.self) { symbol in
                            Button { symbolName = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(symbol == symbolName ? Color.white : Color(hex: colorHex))
                                    .background(symbol == symbolName ? Color(hex: colorHex) : .clear, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: symbol))
                            .accessibilityAddTraits(symbol == symbolName ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        if let message = onSave(name, colorHex, symbolName) {
                            error = message
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
