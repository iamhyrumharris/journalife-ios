import JournalCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations), conforming to public.zip-archive.
    static var journalArchive: UTType {
        UTType(filenameExtension: ArchiveFormat.fileExtension, conformingTo: .zip) ?? .zip
    }
}

/// Export and import archives, storage used, and (in debug builds) sample data.
struct DataSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var exportedArchive: ExportedArchive?
    @State private var isWorking = false
    @State private var workTitle: LocalizedStringResource = "Working…"
    @State private var progress: Double?
    @State private var isImporting = false
    @State private var resultMessage: String?
    @State private var storage: (media: Int64, thumbnails: Int64)?
    @State private var entryCount = 0

    struct ExportedArchive: Identifiable {
        let url: URL
        let summary: String
        var id: URL { url }
    }

    var body: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                Label("Export Archive", systemImage: "square.and.arrow.up")
            }
            // Presentations live on one row, not the Section: a List applies Section modifiers
            // to every row, so several rows tried to present at once and Settings closed instead.
            .task { await refreshStats() }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.journalArchive, .zip]) { result in
                switch result {
                case .success(let url): Task { await importArchive(url) }
                case .failure(let error): resultMessage = error.localizedDescription
                }
            }
            .sheet(item: $exportedArchive) { archive in
                ExportReadySheet(archive: archive)
            }
            .alert("Data", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
            Button {
                isImporting = true
            } label: {
                Label("Import Archive", systemImage: "square.and.arrow.down")
            }
            if isWorking {
                HStack {
                    if let progress {
                        ProgressView(value: progress) { Text(workTitle) }
                    } else {
                        ProgressView()
                        Text(workTitle).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Entries", value: entryCount.formatted())
            if let storage {
                LabeledContent("Photos & Videos", value: storage.media.formatted(.byteCount(style: .file)))
                LabeledContent("Previews", value: storage.thumbnails.formatted(.byteCount(style: .file)))
            }
            #if DEBUG
            Button {
                Task { await generateSampleData() }
            } label: {
                Label("Generate Sample Data (1,000 entries)", systemImage: "wand.and.stars")
            }
            Button(role: .destructive) {
                Task { await deleteSampleData() }
            } label: {
                Label("Delete Sample Data", systemImage: "trash")
            }
            #endif
        } header: {
            Text("Data")
        } footer: {
            Text("An archive holds every entry, tag, photo and video in one file. Importing merges by entry, so importing the same archive twice never makes duplicates.")
        }
        .disabled(isWorking)
    }

    private func refreshStats() async {
        entryCount = app.stores.entries.count()
        storage = await app.stores.media.storageUsed()
    }

    private func export() async {
        app.flushEditors()
        start("Exporting…")
        defer { isWorking = false }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let folder = URL.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Journal \(stamp).\(ArchiveFormat.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        do {
            let service = ArchiveService(modelContainer: app.stores.container)
            let summary = try await service.export(to: url, location: app.stores.location, appVersion: Bundle.main.shortVersion)
            var text = String(AttributedString(localized: "^[\(summary.entryCount) entry](inflect: true) and ^[\(summary.attachmentCount) file](inflect: true).").characters)
            if summary.missingFiles > 0 {
                text += " " + String(AttributedString(localized: "^[\(summary.missingFiles) file](inflect: true) couldn't be found and were skipped.").characters)
            }
            exportedArchive = ExportedArchive(url: url, summary: text)
        } catch {
            resultMessage = String(localized: "Export failed: \(error.localizedDescription)")
        }
    }

    private func importArchive(_ url: URL) async {
        app.flushEditors()
        start("Importing…")
        defer { isWorking = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Copy first: reading a file in iCloud Drive while it changes would break the archive.
            let local = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ArchiveFormat.fileExtension)")
            try FileManager.default.copyItem(at: url, to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            let service = ArchiveService(modelContainer: app.stores.container)
            let summary = try await service.importArchive(from: local, location: app.stores.location)
            app.stores.reloadAfterBackgroundChanges()
            resultMessage = String(AttributedString(localized: "Imported. ^[\(summary.entriesAdded) new entry](inflect: true), ^[\(summary.entriesUpdated) updated entry](inflect: true), \(summary.entriesUnchanged) already up to date.").characters)
        } catch {
            resultMessage = String(localized: "Import failed: \(error.localizedDescription)")
        }
        await refreshStats()
    }

    #if DEBUG
    private func generateSampleData() async {
        start("Generating sample data…")
        progress = 0
        defer {
            isWorking = false
            progress = nil
        }
        let generator = SampleDataGenerator(modelContainer: app.stores.container)
        let stream = AsyncStream<Double>.makeStream()
        let watcher = Task { @MainActor in
            for await value in stream.stream { progress = value }
        }
        do {
            try await generator.generate(location: app.stores.location) { stream.continuation.yield($0) }
            resultMessage = String(localized: "Added 1,000 sample entries.")
        } catch {
            resultMessage = error.localizedDescription
        }
        stream.continuation.finish()
        await watcher.value
        app.stores.reloadAfterBackgroundChanges()
        await refreshStats()
    }

    private func deleteSampleData() async {
        start("Deleting sample data…")
        defer { isWorking = false }
        let generator = SampleDataGenerator(modelContainer: app.stores.container)
        let count = (try? await generator.deleteSampleData()) ?? 0
        app.stores.reloadAfterBackgroundChanges()
        resultMessage = String(AttributedString(localized: "Deleted ^[\(count) sample entry](inflect: true).").characters)
        await refreshStats()
    }
    #endif

    private func start(_ title: LocalizedStringResource) {
        workTitle = title
        progress = nil
        isWorking = true
    }
}

/// Offers the finished archive through the share sheet (which includes Save to Files).
private struct ExportReadySheet: View {
    let archive: DataSettingsSection.ExportedArchive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(archive.url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(archive.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: archive.url) {
                    Label("Save or Share", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Archive Ready")
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
