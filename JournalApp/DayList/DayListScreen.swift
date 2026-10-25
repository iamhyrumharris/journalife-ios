import JournalCore
import JournalUI
import SwiftUI

/// Shown when a calendar day has two or more entries.
struct DayListScreen: View {
    let day: DayKey

    @Environment(AppModel.self) private var app
    @State private var rows: [EntryRowData] = []

    var body: some View {
        List {
            ForEach(rows) { row in
                EntryListRow(row: row)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(JournalColors.background)
        .navigationTitle(day.startDate().formatted(date: .complete, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.createEntry(on: day)
                } label: {
                    Label("New Entry on This Day", systemImage: "plus")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No entries on this day", systemImage: "calendar")
            }
        }
        .task(id: app.stores.changes.revision) {
            rows = app.stores.entries.entries(on: day).map(EntryRowData.init)
        }
    }
}

#Preview {
    NavigationStack { DayListScreen(day: .today) }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
