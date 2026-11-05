import SwiftUI

/// Settings > Reminders: a daily nudge to write, at a chosen time.
struct ReminderSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.reminderEnabled) private var isEnabled = false
    @AppStorage(AppSettings.reminderTime) private var minutes = ReminderScheduler.defaultMinutes
    @AppStorage(AppSettings.reminderOnWrittenDays) private var onWrittenDays = false
    @State private var isDenied = false

    var body: some View {
        Section {
            Toggle("Daily Reminder", isOn: Binding(get: { isEnabled }, set: { setEnabled($0) }))
                // On one row, not the Section: a Form applies Section modifiers to every row.
                .onChange(of: minutes) { app.rescheduleReminders() }
                .onChange(of: onWrittenDays) { app.rescheduleReminders() }
            if isEnabled {
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                Toggle("Remind Even If I've Written", isOn: $onWrittenDays)
            }
            if isDenied {
                Button("Open Settings") { openAppSettings() }
            }
        } header: {
            Text("Reminders")
        } footer: {
            if isDenied {
                Text("Notifications are off for this app. Turn them on in the Settings app to get reminders.")
            } else if isEnabled {
                Text(onWrittenDays
                     ? LocalizedStringKey("You'll get a reminder every day at this time.")
                     : "You won't be reminded on days you've already written.")
            }
        }
    }

    /// The reminder time as a date today, for the picker.
    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 20) * 60 + (parts.minute ?? 0)
        }
    }

    private func setEnabled(_ on: Bool) {
        guard on else {
            isEnabled = false
            app.rescheduleReminders()
            return
        }
        Task {
            if await ReminderScheduler.requestAuthorization() {
                isEnabled = true
                isDenied = false
                app.rescheduleReminders()
            } else {
                isDenied = true
            }
        }
    }
}
