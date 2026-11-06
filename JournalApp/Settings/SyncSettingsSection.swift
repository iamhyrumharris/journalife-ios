import JournalCore
import SwiftUI

/// Settings > Sync: which service, status, last sync, Sync Now, and any conflicted copies.
struct SyncSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.sync
        Section {
            NavigationLink {
                SyncProviderView()
            } label: {
                LabeledContent("Sync With") { Text(sync.kind.label) }
            }
            if sync.isEnabled || sync.kind != .off {
                LabeledContent("Status") {
                    Text(sync.statusText)
                }
                if let error = sync.lastError, !sync.isSyncing {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(sync.isSyncing || !sync.isEnabled)
            }
            if sync.conflictCount > 0 {
                NavigationLink {
                    ConflictedCopiesView()
                } label: {
                    LabeledContent("Conflicted Copies") { Text(sync.conflictCount.formatted()) }
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Sync keeps your journal the same on all your devices. Your phone always keeps its own full copy.")
        }
    }
}

extension SyncProviderKind {
    var label: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .iCloud: "iCloud"
        case .webDAV: "WebDAV"
        }
    }
}

/// Picks Off, iCloud or WebDAV, and sets up the WebDAV server.
private struct SyncProviderView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showsWebDAVForm = false
    @State private var confirmingOff = false

    var body: some View {
        let sync = app.sync
        Form {
            Section {
                choice(.off) { confirmingOff = sync.kind != .off }
                choice(.iCloud) { Task { await sync.useICloud() } }
                    .disabled(!sync.isICloudAvailable)
                choice(.webDAV) { showsWebDAVForm = true }
            } footer: {
                if !sync.isICloudAvailable {
                    Text("iCloud sync needs the app to be signed with a paid Apple Developer team. WebDAV works with any server, such as a NAS or Nextcloud.")
                } else {
                    Text("Switching services uploads your whole journal to the new one. Nothing is deleted from the old one.")
                }
            }

            if showsWebDAVForm || sync.kind == .webDAV {
                Section {
                    TextField("Folder Address", text: $address, prompt: Text(verbatim: "https://nas.local:5006/journal"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("User Name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text(sync.kind == .webDAV ? "Save and Sync" : "Connect")
                            if isConnecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnecting || address.isEmpty || username.isEmpty || password.isEmpty)
                } header: {
                    Text("WebDAV Server")
                } footer: {
                    if let connectError {
                        Text(connectError).foregroundStyle(.orange)
                    } else if let config = WebDAVConfiguration(address: address, username: username), config.isInsecure {
                        Text("This address uses http, so your password would travel unencrypted. Use https for servers outside your home network.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Your journal is stored in this folder as JSON files and a media folder. The password is kept in the Keychain.")
                    }
                }
            }
        }
        .navigationTitle("Sync With")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let config = sync.webDAV {
                address = config.folderURL.absoluteString
                username = config.username
            }
        }
        .confirmationDialog("Turn off sync?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off Sync", role: .destructive) {
                sync.turnOff()
                showsWebDAVForm = false
            }
        } message: {
            Text("This device keeps everything. Changes stop syncing until you turn sync on again.")
        }
    }

    private func choice(_ kind: SyncProviderKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(kind.label)
                    .foregroundStyle(.primary)
                Spacer()
                if app.sync.kind == kind {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func connect() async {
        guard let config = WebDAVConfiguration(address: address, username: username) else {
            connectError = SyncError.invalidServerURL.errorDescription
            return
        }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            try await app.sync.useWebDAV(config, password: password)
            password = ""
            address = config.folderURL.absoluteString
        } catch {
            connectError = SyncError.describe(error)
        }
    }
}

/// Versions of entries that lost a sync conflict. Each can be restored as a new entry.
private struct ConflictedCopiesView: View {
    @Environment(AppModel.self) private var app
    @State private var copies: [ConflictedCopy] = []

    var body: some View {
        List {
            Section {
                ForEach(copies) { copy in
                    NavigationLink {
                        ConflictedCopyDetail(copy: copy) { reload() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(copy.entry.title.isEmpty ? String(copy.entry.bodyPlain.prefix(60)) : copy.entry.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text("Entry for \(copy.entry.entryDate.formatted(date: .abbreviated, time: .shortened)), saved \(copy.savedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("When the same entry was changed on two devices before they synced, the newer change was kept and the other version was saved here.")
            }
        }
        .navigationTitle("Conflicted Copies")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        copies = app.sync.conflictStore.all()
        app.sync.refreshConflicts()
    }
}

private struct ConflictedCopyDetail: View {
    let copy: ConflictedCopy
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !copy.entry.title.isEmpty {
                    Text(copy.entry.title).font(.title2.weight(.semibold))
                }
                Text(copy.entry.bodyPlain)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(copy.entry.entryDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        app.stores.entries.restore(copy)
                        app.sync.conflictStore.delete(copy)
                        onChange()
                        dismiss()
                    } label: {
                        Label("Restore as New Entry", systemImage: "doc.badge.plus")
                    }
                    Button(role: .destructive) {
                        app.sync.conflictStore.delete(copy)
                        onChange()
                        dismiss()
                    } label: {
                        Label("Delete Copy", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
            }
        }
    }
}
