import JournalCore
import JournalUI
import SwiftUI

/// Rename, recolor, change icon, reorder, merge and delete tags.
struct TagManagementView: View {
    @Environment(AppModel.self) private var app
    @State private var tags: [JournalCore.Tag] = []
    @State private var editing: JournalCore.Tag?
    @State private var isCreating = false
    @State private var merging: JournalCore.Tag?
    @State private var deleting: JournalCore.Tag?

    var body: some View {
        List {
            ForEach(tags) { tag in
                Button { editing = tag } label: {
                    HStack {
                        TagChip(tag)
                        Spacer()
                        Text("^[\(app.stores.tags.usageCount(tag)) entry](inflect: true)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                    Button { merging = tag } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                        .tint(.indigo)
                }
                .contextMenu {
                    Button { editing = tag } label: { Label("Edit", systemImage: "pencil") }
                    Button { merging = tag } label: { Label("Merge Into…", systemImage: "arrow.triangle.merge") }
                    Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onMove { from, to in
                var reordered = tags
                reordered.move(fromOffsets: from, toOffset: to)
                app.stores.tags.reorder(reordered)
                refresh()
            }
        }
        .overlay {
            if tags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "tag", description: Text("Tags you add to entries show up here."))
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Label("New Tag", systemImage: "plus") }
            }
        }
        .onAppear(perform: refresh)
        .sheet(item: $editing) { tag in
            TagFormSheet(title: "Edit Tag", name: tag.name, colorHex: tag.colorHex, symbolName: tag.symbolName) { name, color, symbol in
                if app.stores.tags.rename(tag, to: name) == .nameTaken { return "Another tag already has this name. Use Merge to combine them." }
                app.stores.tags.update(tag) {
                    $0.colorHex = color
                    $0.symbolName = symbol
                }
                refresh()
                return nil
            }
        }
        .sheet(isPresented: $isCreating) {
            TagFormSheet(title: "New Tag", name: "", colorHex: nil, symbolName: "tag") { name, color, symbol in
                if app.stores.tags.tag(named: name) != nil { return "A tag with this name already exists." }
                app.stores.tags.create(name: name, colorHex: color, symbolName: symbol)
                refresh()
                return nil
            }
        }
        .sheet(item: $merging) { source in
            MergeTagSheet(source: source, candidates: tags.filter { $0.id != source.id }) { target in
                app.stores.tags.merge(source, into: target)
                refresh()
            }
        }
        .confirmationDialog(
            "Delete this tag?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { tag in
            Button("Delete “\(tag.name)”", role: .destructive) {
                app.stores.tags.softDelete(tag)
                refresh()
            }
        } message: { _ in
            Text("Entries keep their text. The tag is removed from them.")
        }
    }

    private func refresh() {
        tags = app.stores.tags.allTags()
    }
}

private struct MergeTagSheet: View {
    let source: JournalCore.Tag
    let candidates: [JournalCore.Tag]
    var onMerge: (JournalCore.Tag) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates) { target in
                Button {
                    onMerge(target)
                    dismiss()
                } label: {
                    TagChip(target)
                }
            }
            .navigationTitle("Merge “\(source.name)” Into")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    NavigationStack { TagManagementView() }
        .environment(PreviewSupport.model)
}
