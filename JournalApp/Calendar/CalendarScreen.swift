import JournalCore
import JournalUI
import SwiftUI

/// One continuous vertical scroll of months, opening on the current month at the bottom.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.zoomNamespace) private var zoom
    @AppStorage(AppSettings.weekStart) private var weekStart = WeekStart.system
    @State private var model = CalendarModel()
    @State private var pendingNewEntryDay: DayKey?
    @State private var isShowingJumpToDate = false
    @State private var jumpDate = Date.now
    @State private var scrollTarget: String?
    @State private var isVisible = false
    @State private var isStale = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(model.months) { month in
                        monthView(month)
                            .id(month.id)
                            .onAppear {
                                if month.id == model.months.first?.id {
                                    model.loadOlderMonths(stores: app.stores, weekStart: weekStart)
                                }
                            }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 12)
            }
            // A safe-area bar keeps the weekday row pinned under the top bar and insets
            // the months below it, so the first row of dates is never covered.
            .safeAreaBar(edge: .top) { weekdayHeader }
            .defaultScrollAnchor(.bottom)
            // Keeps your place when months above load in while scrolling into the past.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
        .background(JournalColors.background)
        .tabRootToolbar(title: "Calendar") {
            Button {
                scrollTarget = CalendarMonth(year: DayKey.today.year, month: DayKey.today.month, leadingBlanks: 0, dayCount: 0).id
            } label: {
                Label("Jump to Today", systemImage: "calendar.badge.clock")
            }
            Button {
                isShowingJumpToDate = true
            } label: {
                Label("Jump to Date…", systemImage: "calendar.badge.magnifyingglass")
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
        .onChange(of: weekStart) { refresh() }
        .confirmationDialog(
            "New entry",
            isPresented: Binding(get: { pendingNewEntryDay != nil }, set: { if !$0 { pendingNewEntryDay = nil } }),
            titleVisibility: .visible,
            presenting: pendingNewEntryDay
        ) { day in
            Button("Write on \(day.startDate().formatted(date: .long, time: .omitted))") {
                app.createEntry(on: day)
            }
        }
        .sheet(isPresented: $isShowingJumpToDate) { jumpToDateSheet }
    }

    private func refresh() {
        model.refresh(stores: app.stores, weekStart: weekStart)
        isStale = false
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(Array(zip(model.weekdaySymbols, model.fullWeekdaySymbols).enumerated()), id: \.offset) { _, symbol in
                Text(symbol.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(symbol.1)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
    }

    private func monthView(_ month: CalendarMonth) -> some View {
        let today = DayKey.today
        return VStack(spacing: 8) {
            Text(month.firstDay.monthTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<month.leadingBlanks, id: \.self) { _ in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
                ForEach(1...month.dayCount, id: \.self) { number in
                    let day = month.day(number)
                    let summary = model.summaries[day]
                    Button {
                        open(day, summary: summary)
                    } label: {
                        CalendarDayCell(
                            day: day,
                            content: model.content(for: day),
                            count: summary?.count ?? 0,
                            isToday: day == today,
                            isFuture: day > today
                        )
                    }
                    .buttonStyle(.plain)
                    .zoomSource(id: day.id, namespace: zoom)
                }
            }
        }
    }

    private func open(_ day: DayKey, summary: DaySummary?) {
        switch summary?.entryIDs.count ?? 0 {
        case 0:
            pendingNewEntryDay = day
        case 1:
            app.router.push(.entry(summary!.entryIDs[0], zoomSource: day.id))
        default:
            app.router.push(.day(day, zoomSource: day.id))
        }
    }

    private var jumpToDateSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $jumpDate, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Jump to Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { isShowingJumpToDate = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go", role: .confirm) {
                            let day = DayKey(date: jumpDate)
                            model.ensureIncludes(day, stores: app.stores, weekStart: weekStart)
                            isShowingJumpToDate = false
                            scrollTarget = CalendarMonth(year: day.year, month: day.month, leadingBlanks: 0, dayCount: 0).id
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    NavigationStack { CalendarScreen() }
        .environment(PreviewSupport.model)
        .environment(\.thumbnailCache, PreviewSupport.model.thumbnails)
        .preferredColorScheme(.dark)
}
