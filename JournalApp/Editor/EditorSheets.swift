import JournalCore
import JournalUI
import SwiftUI

struct RatingSheet: View {
    @Binding var rating: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Rating")
                .font(.headline)
            RatingPicker(rating: $rating)
            Text("Tap a star again to clear it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .presentationDetents([.height(200)])
    }
}

struct EntryDateSheet: View {
    @State var date: Date
    let timeZone: TimeZone
    var onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    init(date: Date, timeZone: TimeZone, onSave: @escaping (Date) -> Void) {
        _date = State(initialValue: date)
        self.timeZone = timeZone
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                if timeZone != .current {
                    LabeledContent("Time Zone", value: timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier)
                }
            }
            .environment(\.timeZone, timeZone)
            .navigationTitle("Entry Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EntryInfoSheet: View {
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Created", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Words", value: entry.wordCount.formatted())
                LabeledContent("Media", value: entry.liveAttachments.count.formatted())
                LabeledContent("Time Zone", value: entry.timeZone.localizedName(for: .generic, locale: .current) ?? entry.timeZoneID)
                if let placeName = entry.placeName {
                    LabeledContent("Place", value: placeName)
                }
            }
            .navigationTitle("Entry Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
