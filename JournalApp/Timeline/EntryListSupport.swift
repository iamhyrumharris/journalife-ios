import JournalCore
import JournalUI
import SwiftUI

/// Rows grouped under a month header.
struct MonthSection: Identifiable {
    let month: DayKey
    let rows: [EntryRowData]
    var id: DayKey { month }

    static func group(_ rows: [EntryRowData]) -> [MonthSection] {
        var sections: [MonthSection] = []
        var current: [EntryRowData] = []
        var currentMonth: DayKey?
        for row in rows {
            if row.monthKey != currentMonth, let month = currentMonth {
                sections.append(MonthSection(month: month, rows: current))
                current = []
            }
            currentMonth = row.monthKey
            current.append(row)
        }
        if let month = currentMonth { sections.append(MonthSection(month: month, rows: current)) }
        return sections
    }
}

/// An entry row that opens the editor, with swipe to favorite and delete (with a confirm).
struct EntryListRow: View {
    let row: EntryRowData
    var highlightTerms: [String] = []

    @Environment(AppModel.self) private var app
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationLink(value: AppRoute.entry(row.id)) {
            EntryRow(row, highlightTerms: highlightTerms)
        }
        .listRowBackground(JournalColors.background)
        .alignmentGuide(.listRowSeparatorLeading) { _ in EntryRow.dateColumnWidth + 12 }
        .swipeActions(edge: .trailing) {
            // Not role: .destructive: that tells the list the row is going away right now,
            // which dismisses the row before the confirmation dialog can show.
            Button {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                if let entry = app.stores.entries.entry(id: row.id) { app.stores.entries.toggleFavorite(entry) }
            } label: {
                Label(row.isFavorite ? "Unfavorite" : "Favorite", systemImage: row.isFavorite ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
        .confirmationDialog("Delete this entry?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive) {
                if let entry = app.stores.entries.entry(id: row.id) { app.stores.entries.softDelete(entry) }
            }
        } message: {
            Text("Its photos and videos are deleted too.")
        }
    }
}
