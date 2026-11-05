import Foundation
import Observation

/// Owns the chosen provider, runs syncs and publishes status for Settings and the toolbar.
///
/// Sync runs on launch, on returning to the foreground, a few seconds after edits, and in
/// background app refresh (the app calls `syncNow`/`scheduleSoon`; see the spec, Sync and backup).
@MainActor
@Observable
public final class SyncController {
    public private(set) var kind: SyncProviderKind
    public private(set) var webDAV: WebDAVConfiguration?
    public private(set) var isSyncing = false
    public private(set) var step: SyncStep?
    public private(set) var lastSyncAt: Date?
    public private(set) var lastError: String?
    public private(set) var lastReport: SyncReport?
    /// Changes in `Sync/Conflicts`, so Settings can show the count.
    public private(set) var conflictCount = 0

    /// The CloudKit container, or nil when this build isn't signed for iCloud.
    public let iCloudContainerIdentifier: String?
    public var isICloudAvailable: Bool { iCloudContainerIdentifier != nil }

    /// Entries open in the editor (see `SyncEngine.isEntryOpen`).
    @ObservationIgnored public var isEntryOpen: (UUID) -> Bool = { _ in false } {
        didSet { engine?.isEntryOpen = isEntryOpen }
    }

    @ObservationIgnored private let stores: JournalStores
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var revisionAfterSync = -1

    static let kindKey = "sync.provider"
    static let webDAVKey = "sync.webdav"
    /// Seconds after an edit before syncing, so typing doesn't sync every keystroke.
    public static let editDelay: Duration = .seconds(8)

    public init(stores: JournalStores, iCloudContainerIdentifier: String?, defaults: UserDefaults = .standard) {
        self.stores = stores
        self.defaults = defaults
        self.iCloudContainerIdentifier = iCloudContainerIdentifier
        self.webDAV = defaults.data(forKey: Self.webDAVKey).flatMap { try? JSONDecoder().decode(WebDAVConfiguration.self, from: $0) }
        var kind = defaults.string(forKey: Self.kindKey).flatMap(SyncProviderKind.init(rawValue:)) ?? .off
        if kind == .iCloud && iCloudContainerIdentifier == nil { kind = .off }
        self.kind = kind
        rebuildEngine()
        refreshConflicts()
    }

    // MARK: Choosing a provider

    /// Turns sync off. Nothing is deleted locally or remotely.
    public func turnOff() {
        setKind(.off)
    }

    public func useICloud() async {
        guard isICloudAvailable else { return }
        setKind(.iCloud)
        await syncNow()
    }

    /// Checks the server, saves the password in the Keychain and switches to WebDAV.
    /// Throws (and changes nothing) if the server can't be reached or refuses the login.
    public func useWebDAV(_ configuration: WebDAVConfiguration, password: String) async throws {
        let provider = WebDAVSyncProvider(configuration: configuration, password: password)
        try await provider.prepare()
        try Keychain.set(password, account: configuration.keychainAccount)
        if let old = webDAV, old.keychainAccount != configuration.keychainAccount {
            Keychain.delete(account: old.keychainAccount)
        }
        webDAV = configuration
        defaults.set(try? JSONEncoder().encode(configuration), forKey: Self.webDAVKey)
        setKind(.webDAV)
        await syncNow()
    }

    private func setKind(_ kind: SyncProviderKind) {
        self.kind = kind
        defaults.set(kind.rawValue, forKey: Self.kindKey)
        lastError = nil
        lastReport = nil
        rebuildEngine()
    }

    private func rebuildEngine() {
        debounce?.cancel()
        let provider: (any SyncProvider)?
        let stateName: String
        switch kind {
        case .off:
            provider = nil
            stateName = ""
        case .iCloud:
            provider = iCloudContainerIdentifier.map { CloudKitSyncProvider(containerIdentifier: $0) }
            stateName = "icloud"
        case .webDAV:
            if let webDAV, let password = Keychain.get(account: webDAV.keychainAccount) {
                provider = WebDAVSyncProvider(configuration: webDAV, password: password)
            } else {
                provider = nil
                lastError = SyncError.missingCredentials.errorDescription
            }
            stateName = webDAV?.stateName ?? "webdav"
        }
        guard let provider else {
            engine = nil
            lastSyncAt = nil
            stores.syncHooks.reset()
            return
        }
        let engine = SyncEngine(provider: provider, stores: stores, stateName: stateName)
        engine.isEntryOpen = isEntryOpen
        engine.installHooks()
        self.engine = engine
        lastSyncAt = engine.lastSyncAt
    }

    // MARK: Running

    public var isEnabled: Bool { engine != nil }

    /// Syncs now. If a sync is already running, one more runs after it.
    public func syncNow(includeFiles: Bool = true) async {
        debounce?.cancel()
        guard let engine else { return }
        if isSyncing {
            runAgain = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            step = nil
        }
        repeat {
            runAgain = false
            do {
                let report = try await engine.sync(includeFiles: includeFiles) { [weak self] in self?.step = $0 }
                lastReport = report
                lastError = nil
                lastSyncAt = engine.lastSyncAt
            } catch is CancellationError {
                return
            } catch {
                lastError = SyncError.describe(error)
                logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            refreshConflicts()
            revisionAfterSync = stores.changes.revision
        } while runAgain && engine === self.engine
    }

    /// Call when the journal changes. Syncs a few seconds later, once edits settle.
    /// `force` syncs even when nothing changed locally (for example when an editor closes,
    /// so remote changes held back for it come in).
    public func scheduleSoon(force: Bool = false) {
        guard engine != nil else { return }
        // Changes sync itself made don't need another sync.
        guard force || stores.changes.revision != revisionAfterSync else { return }
        if isSyncing {
            runAgain = true
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.editDelay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    // MARK: Conflicted copies

    public var conflictStore: ConflictStore { ConflictStore(location: stores.location) }

    public func refreshConflicts() {
        conflictCount = conflictStore.count
    }

    /// Text for the status line: what's happening now, or when the last sync finished.
    public var statusText: String {
        if let step {
            switch step {
            case .checking: return String(localized: "Connecting…")
            case .downloadingChanges: return String(localized: "Checking for changes…")
            case .uploadingFiles(let done, let total): return String(localized: "Uploading files (\(done + 1) of \(total))…")
            case .downloadingFiles(let done, let total): return String(localized: "Downloading files (\(done + 1) of \(total))…")
            case .uploadingChanges(let done, let total): return String(localized: "Uploading changes (\(done) of \(total))…")
            }
        }
        if isSyncing { return String(localized: "Syncing…") }
        if let lastSyncAt {
            return String(localized: "Last synced \(lastSyncAt.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Not synced yet")
    }
}
