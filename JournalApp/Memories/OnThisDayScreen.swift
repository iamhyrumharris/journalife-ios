import JournalCore
import JournalUI
import SwiftUI

/// Entries written on this date in earlier years, grouped by year, newest first.
/// The arrows step to the day before or after.
struct OnThisDayScreen: View {
    @Environment(AppModel.self) private var app
    @State private var day: DayKey
    @State private var sections: [YearSection] = []
    @State private var isLoaded = false

    init(day: DayKey) {
        _day = State(initialValue: day)
    }

    struct YearSection: Identifiable {
        let year: Int
        let yearsAgo: Int
        let rows: [EntryRowData]
        var id: Int { year }
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        EntryListRow(row: row)
                    }
                } header: {
                    Text("^[\(section.yearsAgo) year](inflect: true) ago · \(String(section.year))")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                        .background { HeaderBackground() }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(JournalColors.background)
        .overlay {
            if sections.isEmpty && isLoaded {
                ContentUnavailableView {
                    Label("Nothing on this day yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Entries you wrote on \(dayTitle) in past years will show up here.")
                }
            }
        }
        .solidNavigationHeader()
        .navigationTitle("On This Day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("On This Day")
                        .font(.headline)
                    Text(dayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { step(by: -1) } label: {
                    Label("Previous Day", systemImage: "chevron.left")
                }
                Button { step(by: 1) } label: {
                    Label("Next Day", systemImage: "chevron.right")
                }
            }
        }
        .task(id: TaskKey(day: day, revision: app.stores.changes.revision)) { refresh() }
    }

    private struct TaskKey: Hashable {
        let day: DayKey
        let revision: Int
    }

    /// "October 28"
    private var dayTitle: String {
        day.startDate().formatted(.dateTime.month(.wide).day())
    }

    private func step(by days: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let year = DayKey.today.year
        var next = day
        repeat {
            let noon = next.startDate(in: .gmt).addingTimeInterval(12 * 3600)
            guard let date = calendar.date(byAdding: .day, value: days, to: noon) else { return }
            // Stay in the current year, so the page always looks back from today's year.
            let moved = DayKey(date: date, timeZone: .gmt)
            next = DayKey(year: year, month: moved.month, day: moved.day)
        } while next.month == 2 && next.day == 29 && !OnThisDay.isLeapYear(year)
        day = next
    }

    private func refresh() {
        var byYear: [Int: [EntryRowData]] = [:]
        for entry in app.stores.entries.entriesOnThisDay(day) {
            byYear[entry.dayKey.year, default: []].append(EntryRowData(entry))
        }
        sections = byYear.keys.sorted(by: >).map { year in
            YearSection(year: year, yearsAgo: day.year - year, rows: byYear[year] ?? [])
        }
        isLoaded = true
    }
}

#Preview {
    NavigationStack { OnThisDayScreen(day: .today) }
        .environment(PreviewSupport.model)
        .preferredColorScheme(.dark)
}
