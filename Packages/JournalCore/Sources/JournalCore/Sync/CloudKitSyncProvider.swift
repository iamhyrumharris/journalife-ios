import CloudKit
import Foundation

/// Syncs to the user's private iCloud database. No account needed beyond the person's own
/// Apple ID, and each family member syncs only their own journal.
///
/// Everything lives in one custom zone, `Journal`:
/// - `Entry` and `Tag` records named by `SyncRecord.key`, holding the record JSON in `json`
/// - `Media` records named `media.<UUID>`, holding the original file as a `CKAsset` in `file`
///
// DECISION: the spec names CKSyncEngine. This uses CloudKit's zone-change and modify calls
// directly instead, because the engine (`SyncEngine`) already does the change tracking, merging
// and scheduling CKSyncEngine would duplicate, and both providers then share one code path.
// CKSyncEngine could replace this later if push-triggered sync is wanted.
public actor CloudKitSyncProvider: SyncProvider {
    public nonisolated let kind = SyncProviderKind.iCloud
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "Journal", ownerName: CKCurrentUserDefaultName)
    private var zoneReady = false

    static let jsonKey = "json"
    static let modifiedAtKey = "modifiedAt"
    static let fileKey = "file"

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    public func prepare() async throws {
        let status = try await container.accountStatus()
        switch status {
        case .available:
            break
        case .noAccount:
            throw SyncError.iCloudAccountUnavailable(String(localized: "Sign in to iCloud in the Settings app to sync."))
        case .restricted:
            throw SyncError.iCloudAccountUnavailable(String(localized: "iCloud is restricted on this device."))
        case .temporarilyUnavailable:
            throw SyncError.iCloudAccountUnavailable(String(localized: "iCloud is temporarily unavailable. Try again in a moment."))
        default:
            throw SyncError.iCloudAccountUnavailable(String(localized: "iCloud couldn't be reached."))
        }
        if !zoneReady {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneReady = true
        }
    }

    // MARK: Records

    public func pullChanges(since token: Data?) async throws -> SyncPage {
        let changeToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            // Media records come without their asset; files download one at a time when needed.
            let result = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: changeToken,
                desiredKeys: [Self.jsonKey, Self.modifiedAtKey]
            )
            var records: [SyncRecord] = []
            for (_, modification) in result.modificationResultsByID {
                guard case .success(let change) = modification else { continue }
                let record = change.record
                guard let kind = Self.kind(of: record.recordType),
                      let payload = record[Self.jsonKey] as? Data,
                      let syncRecord = try? SyncRecord.decode(kind: kind, payload: payload) else { continue }
                records.append(syncRecord)
            }
            let newToken = try? NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return SyncPage(records: records, token: newToken, hasMore: result.moreComing)
        } catch let error as CKError where error.code == .changeTokenExpired && changeToken != nil {
            // Start over from the beginning; merging makes a full pull safe.
            return try await pullChanges(since: nil)
        } catch let error as CKError where error.code == .zoneNotFound {
            // The zone was deleted (for example from iCloud settings). Make it again so new
            // changes have somewhere to go.
            // DECISION: records this device already sent aren't re-sent automatically after that.
            zoneReady = false
            try await prepare()
            return SyncPage(records: [], token: nil)
        }
    }

    public func pushChanges(_ records: [SyncRecord], token: Data?) async throws -> SyncPushResult {
        guard !records.isEmpty else { return SyncPushResult(saved: []) }
        let ckRecords = records.map { record -> CKRecord in
            let ckRecord = CKRecord(recordType: Self.recordType(record.kind), recordID: CKRecord.ID(recordName: record.key, zoneID: zoneID))
            ckRecord[Self.jsonKey] = record.payload as NSData
            ckRecord[Self.modifiedAtKey] = record.modifiedAt as NSDate
            return ckRecord
        }
        // DECISION: .allKeys overwrites the server copy. The engine pulled and merged just before,
        // so what it sends is already the last writer's version.
        let (saveResults, _) = try await database.modifyRecords(saving: ckRecords, deleting: [], savePolicy: .allKeys, atomically: false)
        var saved: Set<String> = []
        var failure: (any Error)?
        for (id, result) in saveResults {
            switch result {
            case .success: saved.insert(id.recordName)
            case .failure(let error): failure = failure ?? error
            }
        }
        return SyncPushResult(saved: saved, failure: failure)
    }

    // MARK: Files

    private func mediaID(_ file: SyncFile) -> CKRecord.ID {
        CKRecord.ID(recordName: "media.\(file.id.uuidString)", zoneID: zoneID)
    }

    public func uploadFile(_ file: SyncFile, from url: URL) async throws {
        let id = mediaID(file)
        // Skip files another device already uploaded.
        if let existing = try await database.records(for: [id], desiredKeys: [])[id] {
            switch existing {
            case .success: return
            case .failure(let error as CKError) where error.code == .unknownItem: break
            case .failure(let error): throw error
            }
        }
        let record = CKRecord(recordType: "Media", recordID: id)
        record[Self.fileKey] = CKAsset(fileURL: url)
        record["fileExtension"] = file.fileExtension as NSString
        record["byteSize"] = NSNumber(value: file.byteSize)
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        if case .failure(let error)? = results[id] { throw error }
    }

    public func downloadFile(_ file: SyncFile, to url: URL) async throws -> Bool {
        let id = mediaID(file)
        guard let result = try await database.records(for: [id], desiredKeys: [Self.fileKey])[id] else { return false }
        switch result {
        case .success(let record):
            guard let asset = record[Self.fileKey] as? CKAsset, let source = asset.fileURL else { return false }
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: source, to: url)
            return true
        case .failure(let error as CKError) where error.code == .unknownItem:
            return false
        case .failure(let error):
            throw error
        }
    }

    public func deleteFile(_ file: SyncFile) async throws {
        let id = mediaID(file)
        let (_, results) = try await database.modifyRecords(saving: [], deleting: [id], savePolicy: .allKeys, atomically: false)
        if case .failure(let error as CKError)? = results[id], error.code != .unknownItem { throw error }
    }

    // MARK: Record types

    static func recordType(_ kind: SyncRecordKind) -> CKRecord.RecordType {
        switch kind {
        case .entry: "Entry"
        case .tag: "Tag"
        }
    }

    static func kind(of recordType: CKRecord.RecordType) -> SyncRecordKind? {
        switch recordType {
        case "Entry": .entry
        case "Tag": .tag
        default: nil
        }
    }
}

extension SyncError {
    /// A friendlier message for common CloudKit errors.
    static func describe(_ error: any Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure: return String(localized: "No internet connection.")
            case .notAuthenticated: return String(localized: "Sign in to iCloud in the Settings app to sync.")
            case .quotaExceeded: return String(localized: "Your iCloud storage is full.")
            case .serviceUnavailable, .requestRateLimited, .zoneBusy: return String(localized: "iCloud is busy. Sync will try again soon.")
            default: break
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return String(localized: "No internet connection.")
            case .cannotFindHost, .cannotConnectToHost: return String(localized: "The server couldn't be reached.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return String(localized: "The server's security certificate isn't trusted.")
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "Use an https address, or a server on your local network.")
            default: break
            }
        }
        return error.localizedDescription
    }
}
