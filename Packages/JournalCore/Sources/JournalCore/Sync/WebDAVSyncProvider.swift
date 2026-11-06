import CryptoKit
import Foundation

/// Where to sync over WebDAV. The password lives in the Keychain under `keychainAccount`.
public struct WebDAVConfiguration: Codable, Sendable, Equatable {
    /// The folder on the server, always ending in `/`.
    public var folderURL: URL
    public var username: String

    /// Nil when the address isn't an http or https URL with a host.
    public init?(address: String, username: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        self.folderURL = url
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var keychainAccount: String { "webdav:\(username)@\(folderURL.absoluteString)" }

    /// Names the sync state file, so another folder or server starts fresh.
    public var stateName: String {
        let digest = SHA256.hash(data: Data(keychainAccount.utf8))
        return "webdav-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// True for plain http to a server that isn't on the local network, where the password
    /// would travel unencrypted over the internet.
    public var isInsecure: Bool {
        guard folderURL.scheme?.lowercased() == "http", let host = folderURL.host()?.lowercased() else { return false }
        let local = host.hasSuffix(".local") || !host.contains(".") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
            || host.hasPrefix("172.") || host == "127.0.0.1"
        return !local
    }
}

/// Syncs to a folder on any WebDAV server (a NAS, Nextcloud, and so on).
///
/// Layout in the folder (see docs/SYNC_FORMAT.md):
/// - `manifest.json`: every record's key and `modifiedAt`, for change detection
/// - `entries/<UUID>.json`, `tags/<UUID>.json`: the same JSON shapes as the archive, plus `deletedAt`
/// - `media/<xx>/<uuid>.<ext>`: original media files
public actor WebDAVSyncProvider: SyncProvider {
    public nonisolated let kind = SyncProviderKind.webDAV
    private nonisolated let client: WebDAVClient
    private var preparedFolders: Set<String> = []

    static let formatVersion = 1
    static let concurrency = 6

    public init(configuration: WebDAVConfiguration, password: String, sessionConfiguration: URLSessionConfiguration = .default) {
        client = WebDAVClient(base: configuration.folderURL, username: configuration.username, password: password, configuration: sessionConfiguration)
    }

    public func prepare() async throws {
        if preparedFolders.isEmpty {
            try await client.ensureRootFolder()
        }
        for folder in ["entries/", "tags/", "media/"] where !preparedFolders.contains(folder) {
            try await client.makeFolder(folder)
            preparedFolders.insert(folder)
        }
        preparedFolders.insert("")
    }

    // MARK: Records

    public func pullChanges(since token: Data?) async throws -> SyncPage {
        let (manifest, _) = try await fetchManifest()
        var seen = Self.decodeToken(token)
        let changed = manifest.records.filter { seen[$0.key] != $0.value }.map(\.key)
        let fetched = try await fetch(changed)
        var records: [SyncRecord] = []
        for (key, data) in fetched {
            guard let kind = Self.kind(ofKey: key), let record = try? SyncRecord.decode(kind: kind, payload: data) else { continue }
            records.append(record)
            seen[key] = manifest.records[key]
        }
        return SyncPage(records: records, token: Self.encodeToken(seen))
    }

    public func pushChanges(_ records: [SyncRecord], token: Data?) async throws -> SyncPushResult {
        guard !records.isEmpty else { return SyncPushResult(saved: []) }
        let client = self.client
        var saved: [SyncRecord] = []
        var failure: (any Error)?
        try await withThrowingTaskGroup(of: (SyncRecord, (any Error)?).self) { group in
            var queue = records.makeIterator()
            func addNext() {
                guard let record = queue.next() else { return }
                group.addTask {
                    do {
                        try await client.put(Self.path(forKey: record.key), data: record.payload, contentType: "application/json")
                        return (record, nil)
                    } catch {
                        return (record, error)
                    }
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let (record, error) = try await group.next() {
                if let error { failure = failure ?? error } else { saved.append(record) }
                addNext()
            }
        }
        guard !saved.isEmpty else { return SyncPushResult(saved: [], failure: failure) }

        // Record the new versions in the manifest. If another device wrote it at the same
        // time, the server refuses (If-Match) and we merge again.
        let stamps = Dictionary(saved.map { ($0.key, Self.stamp($0.modifiedAt)) }, uniquingKeysWith: { a, _ in a })
        var attempt = 0
        while true {
            let (fetched, etag) = try await fetchManifest()
            var manifest = fetched
            manifest.records.merge(stamps) { _, new in new }
            manifest.updatedAt = .now
            let data = try ArchiveFormat.makeEncoder().encode(manifest)
            do {
                try await client.put("manifest.json", data: data, contentType: "application/json", ifMatch: etag, ifNoneMatchAny: etag == nil)
                break
            } catch let error as SyncError where error == .server(status: 412, path: "manifest.json") && attempt < 5 {
                attempt += 1
            }
        }

        var seen = Self.decodeToken(token)
        seen.merge(stamps) { _, new in new }
        return SyncPushResult(saved: Set(saved.map(\.key)), token: Self.encodeToken(seen), failure: failure)
    }

    private func fetchManifest() async throws -> (WebDAVManifest, String?) {
        guard let (data, response) = try await client.get("manifest.json") else {
            return (WebDAVManifest(formatVersion: Self.formatVersion, updatedAt: .now, records: [:]), nil)
        }
        let manifest = try ArchiveFormat.makeDecoder().decode(WebDAVManifest.self, from: data)
        guard manifest.formatVersion <= Self.formatVersion else { throw SyncError.newerFormat(manifest.formatVersion) }
        return (manifest, response.value(forHTTPHeaderField: "ETag"))
    }

    /// Downloads record files a few at a time. A file listed in the manifest but missing on the
    /// server is skipped, so it's fetched again next time.
    private func fetch(_ keys: [String]) async throws -> [(String, Data)] {
        let client = self.client
        return try await withThrowingTaskGroup(of: (String, Data?).self) { group in
            var queue = keys.makeIterator()
            func addNext() {
                guard let key = queue.next() else { return }
                group.addTask { (key, try await client.get(Self.path(forKey: key))?.0) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            var results: [(String, Data)] = []
            while let (key, data) = try await group.next() {
                if let data { results.append((key, data)) }
                addNext()
            }
            return results
        }
    }

    // MARK: Files

    public func uploadFile(_ file: SyncFile, from url: URL) async throws {
        let path = "media/" + file.relativePath
        if let size = try await client.size(of: path), size == file.byteSize || file.byteSize == 0 { return }
        let folder = "media/\(file.relativePath.prefix(2))/"
        if !preparedFolders.contains(folder) {
            try await client.makeFolder(folder)
            preparedFolders.insert(folder)
        }
        try await client.upload(path, from: url)
    }

    public func downloadFile(_ file: SyncFile, to url: URL) async throws -> Bool {
        try await client.download("media/" + file.relativePath, to: url)
    }

    public func deleteFile(_ file: SyncFile) async throws {
        try await client.delete("media/" + file.relativePath)
    }

    // MARK: Paths and tokens

    nonisolated static func path(forKey key: String) -> String {
        let parts = key.split(separator: ".", maxSplits: 1)
        let folder = parts.first == "tag" ? "tags" : "entries"
        return "\(folder)/\(parts.last ?? "").json"
    }

    nonisolated static func kind(ofKey key: String) -> SyncRecordKind? {
        key.split(separator: ".", maxSplits: 1).first.flatMap { SyncRecordKind(rawValue: String($0)) }
    }

    nonisolated static func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// The token is the part of the manifest this device has already pulled.
    nonisolated static func decodeToken(_ token: Data?) -> [String: String] {
        token.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    nonisolated static func encodeToken(_ seen: [String: String]) -> Data? {
        try? JSONEncoder().encode(seen)
    }
}

struct WebDAVManifest: Codable, Sendable {
    var formatVersion: Int
    var updatedAt: Date
    /// `SyncRecord.key` → `modifiedAt` as an ISO 8601 string.
    var records: [String: String]
}

// MARK: HTTP

/// The few WebDAV requests sync needs: PROPFIND, MKCOL, GET, HEAD, PUT and DELETE.
final class WebDAVClient: Sendable {
    let base: URL
    private let session: URLSession
    private let authorization: String

    init(base: URL, username: String, password: String, configuration: URLSessionConfiguration) {
        self.base = base
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: WebDAVAuthDelegate(username: username, password: password), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    func url(_ path: String) -> URL {
        URL(string: base.absoluteString + path) ?? base
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        // Sent up front so Basic-auth servers don't need a round trip per request. Digest servers
        // ignore it and challenge instead, which the delegate answers.
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func check(_ response: HTTPURLResponse, _ path: String, allowing extra: Set<Int> = []) throws {
        let status = response.statusCode
        if (200..<300).contains(status) || extra.contains(status) { return }
        if status == 401 || status == 403 { throw SyncError.authenticationFailed }
        throw SyncError.server(status: status, path: path.isEmpty ? "/" : path)
    }

    /// Checks the folder exists and is a WebDAV collection, creating it if it doesn't.
    func ensureRootFolder() async throws {
        var request = self.request("PROPFIND", "")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (_, response) = try await send(request)
        switch response.statusCode {
        case 207, 200:
            return
        case 404:
            try await makeFolder("")
        case 405, 501:
            throw SyncError.notAWebDAVFolder
        default:
            try check(response, "")
        }
    }

    /// MKCOL. A folder that already exists (405) is fine.
    func makeFolder(_ path: String) async throws {
        let (_, response) = try await send(request("MKCOL", path))
        try check(response, path, allowing: [405])
    }

    /// GET. Nil when the file doesn't exist.
    func get(_ path: String) async throws -> (Data, HTTPURLResponse)? {
        let (data, response) = try await send(request("GET", path))
        if response.statusCode == 404 { return nil }
        try check(response, path)
        return (data, response)
    }

    /// HEAD. The file's size, or nil when it doesn't exist.
    func size(of path: String) async throws -> Int64? {
        let (_, response) = try await send(request("HEAD", path))
        if response.statusCode == 404 { return nil }
        try check(response, path)
        return response.expectedContentLength >= 0 ? response.expectedContentLength : 0
    }

    func put(_ path: String, data: Data, contentType: String, ifMatch: String? = nil, ifNoneMatchAny: Bool = false) async throws {
        var request = self.request("PUT", path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if ifNoneMatchAny { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        request.httpBody = data
        let (_, response) = try await send(request)
        try check(response, path)
    }

    func upload(_ path: String, from file: URL) async throws {
        var request = self.request("PUT", path)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (_, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try check(http, path)
    }

    /// Downloads to `destination`, replacing it. Returns false when the file doesn't exist.
    func download(_ path: String, to destination: URL) async throws -> Bool {
        var request = self.request("GET", path)
        request.timeoutInterval = 600
        let (temp, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return false }
        try check(http, path)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
        return true
    }

    /// DELETE. A file that's already gone is fine.
    func delete(_ path: String) async throws {
        let (_, response) = try await send(request("DELETE", path))
        try check(response, path, allowing: [404])
    }
}

/// Answers Basic and Digest challenges with the saved credentials, once.
private final class WebDAVAuthDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let username: String
    let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount == 0 else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
    }
}
