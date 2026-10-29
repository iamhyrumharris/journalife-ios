import JournalCore
import JournalUI
import SwiftUI

/// Settings, presented as a sheet from any tab.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.theme) private var theme = AppTheme.system
    @AppStorage(AppSettings.accent) private var accent = AccentChoice.blue
    @AppStorage(AppSettings.serifBody) private var serifBody = false
    @AppStorage(AppSettings.textSize) private var textSize = EntryTextSize.large
    @AppStorage(AppSettings.timelineThumbnails) private var timelineThumbnails = false
    @AppStorage(AppSettings.weekStart) private var weekStart = WeekStart.system

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Accent Color", selection: $accent) {
                        ForEach(AccentChoice.allCases) { choice in
                            Label { Text(choice.name) } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(choice.color)
                            }
                            .tag(choice)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Text Size", selection: $textSize) {
                        ForEach(EntryTextSize.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Serif Font for Entries", isOn: $serifBody)
                    Toggle("Photos in Timeline", isOn: $timelineThumbnails)
                }

                Section {
                    Picker("Week Starts On", selection: $weekStart) {
                        ForEach(WeekStart.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Calendar")
                }

                ReminderSettingsSection()

                SecuritySettingsSection()

                Section("Tags") {
                    NavigationLink {
                        TagManagementView()
                    } label: {
                        Label("Manage Tags", systemImage: "tag")
                    }
                }

                DataSettingsSection()

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.buildNumber)
                    NavigationLink("Acknowledgements") {
                        ScrollView {
                            Text("This app is built only with Apple frameworks and contains no third-party code.")
                                .padding()
                        }
                        .navigationTitle("Acknowledgements")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
    }
}

private struct SecuritySettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppSettings.lockEnabled) private var lockEnabled = false
    @AppStorage(AppSettings.autoLockDelay) private var autoLockDelay = AutoLockDelay.immediately
    @State private var message: LocalizedStringResource?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { lockEnabled }, set: { setLock($0) })) {
                Text("Require \(Text(AppLock.biometryName))")
            }
            if lockEnabled {
                Picker("Auto-Lock", selection: $autoLockDelay) {
                    ForEach(AutoLockDelay.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("Security")
        } footer: {
            if let message {
                Text(message)
            } else {
                Text("When on, the journal is hidden in the app switcher and asks to unlock when you come back.")
            }
        }
    }

    private func setLock(_ on: Bool) {
        guard on else {
            lockEnabled = false
            return
        }
        guard AppLock.canAuthenticate else {
            message = "Set up Face ID or a passcode in the Settings app first."
            return
        }
        Task {
            if await app.lock.confirmEnabling() {
                lockEnabled = true
                message = nil
            }
        }
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }
    var buildNumber: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–" }
}

#Preview {
    SettingsSheet()
        .environment(PreviewSupport.model)
}
