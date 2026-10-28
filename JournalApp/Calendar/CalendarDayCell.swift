import JournalCore
import JournalUI
import SwiftUI

/// A square day cell. Photo days fill edge to edge with the cover; today has an accent ring
/// around its number, so it never looks like a day that only has text.
struct CalendarDayCell: View {
    let day: DayKey
    let content: CalendarCellContent
    let count: Int
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background { background }
            .overlay { border }
            .overlay {
                Text(verbatim: "\(day.day)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(numberColor)
                    .shadow(color: hasPhoto ? .black.opacity(0.7) : .clear, radius: 2, y: 1)
                    .frame(width: 28, height: 28)
                    .overlay {
                        if isToday {
                            Circle()
                                .strokeBorder(.tint, lineWidth: 2.5)
                                .shadow(color: hasPhoto ? .black.opacity(0.5) : .clear, radius: 2)
                        }
                    }
            }
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text(verbatim: "\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(JournalColors.badge, in: .circle)
                        .padding(3)
                }
            }
            .opacity(isFuture ? 0.4 : 1)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private var hasPhoto: Bool {
        if case .photo = content { true } else { false }
    }

    @ViewBuilder
    private var background: some View {
        switch content {
        case .photo(let cover):
            ThumbnailImage(id: cover.id, size: .small)
        case .tinted:
            Rectangle().fill(.tint.opacity(0.3))
        case .empty:
            Rectangle().fill(JournalColors.emptyDay)
        }
    }

    @ViewBuilder
    private var border: some View {
        EmptyView()
    }

    private var numberColor: Color {
        if hasPhoto { return .white }
        return count > 0 ? .primary : .secondary
    }

    private var accessibilityLabel: Text {
        let date = day.startDate().formatted(.dateTime.month(.wide).day())
        let entries: Text = count == 0 ? Text("no entries") : Text("^[\(count) entry](inflect: true)")
        let today: Text = isToday ? Text(", today") : Text(verbatim: "")
        return Text("\(date), \(entries)\(today)")
    }
}

#Preview {
    HStack(spacing: 2) {
        CalendarDayCell(day: .today, content: .empty, count: 0, isToday: true, isFuture: false)
        CalendarDayCell(day: DayKey(year: 2026, month: 10, day: 3), content: .tinted, count: 2, isToday: false, isFuture: false)
        CalendarDayCell(day: DayKey(year: 2026, month: 10, day: 4), content: .empty, count: 0, isToday: false, isFuture: false)
        CalendarDayCell(day: DayKey(year: 2026, month: 10, day: 30), content: .empty, count: 0, isToday: false, isFuture: true)
    }
    .frame(width: 220)
    .padding()
    .preferredColorScheme(.dark)
}
