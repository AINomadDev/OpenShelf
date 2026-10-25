import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case googleDrive, iCloud, s3, gcs, azureBlob, s3Compatible, cloudflareR2, backblazeB2, idriveE2, other
    var id: String { rawValue }
    static var selectable: [Provider] { allCases.filter { $0 != .other } }
    var title: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .iCloud: return "iCloud Drive"
        case .s3: return "Amazon S3"
        case .gcs: return "Google Cloud Storage"
        case .azureBlob: return "Azure Blob Storage"
        case .s3Compatible: return "S3-compatible storage"
        case .cloudflareR2: return "Cloudflare R2"
        case .backblazeB2: return "Backblaze B2"
        case .idriveE2: return "IDrive e2"
        case .other: return "Other storage"
        }
    }
    var backend: String {
        switch self {
        case .googleDrive: return "drive"
        case .iCloud: return "iclouddrive"
        case .s3, .s3Compatible, .cloudflareR2, .idriveE2: return "s3"
        case .gcs: return "google cloud storage"
        case .azureBlob: return "azureblob"
        case .backblazeB2: return "b2"
        case .other: return ""
        }
    }
    // Value of rclone's S3 `provider` option, which tunes request signing and quirks per vendor.
    var s3Flavor: String? {
        switch self {
        case .s3: return "AWS"
        case .s3Compatible: return "Other"
        case .cloudflareR2: return "Cloudflare"
        case .idriveE2: return "IDrive"
        default: return nil
        }
    }
    var symbol: String {
        switch self {
        case .googleDrive: return "triangle"
        case .iCloud: return "icloud"
        case .s3, .s3Compatible, .idriveE2: return "shippingbox"
        case .cloudflareR2: return "cloud.bolt"
        case .backblazeB2: return "flame"
        case .gcs: return "cloud"
        case .azureBlob: return "square.stack.3d.up"
        case .other: return "externaldrive"
        }
    }
    var isObjectStorage: Bool { [.s3, .gcs, .azureBlob, .s3Compatible, .cloudflareR2, .backblazeB2, .idriveE2].contains(self) }
    // Egress-priced object storage is treated as an archive by default.
    var prefersArchive: Bool { isObjectStorage }
    // Free allowance advertised by pay-as-you-go archive providers; nil when there is no fixed allowance.
    // iCloud Drive exposes no storage-info call; Google Shared Drives report none either (detected at refresh time).
    var reportsQuota: Bool { self != .iCloud }
    var freeTierBytes: Int64? { [.cloudflareR2, .backblazeB2, .idriveE2].contains(self) ? 10_000_000_000 : nil }
    // Providers where reading data back can produce a surprise bill.
    var chargesEgress: Bool { [.s3, .gcs, .azureBlob, .s3Compatible].contains(self) }
    var egressNote: String? {
        switch self {
        case .s3, .gcs, .azureBlob: return "Downloads are billed per GB. Archive here; restore only when needed."
        case .cloudflareR2: return "R2 charges no egress fees. Storage beyond 10 GB and requests beyond the free tier are billed."
        case .backblazeB2: return "B2 downloads are free up to 3× your average stored data, then billed per GB."
        case .idriveE2: return "e2 includes a free download allowance based on your stored data; check your plan."
        case .s3Compatible: return "Check your provider's download and request pricing."
        default: return nil
        }
    }
}

// Step-by-step setup help shown in the Add storage flow so credentials can be created without hunting through docs.
struct ProviderGuide {
    let steps: [String]
    let consoleURL: URL?
    let consoleLabel: String
}

extension Provider {
    var guide: ProviderGuide? {
        func guide(_ steps: [String], _ url: String, _ label: String) -> ProviderGuide { ProviderGuide(steps: steps, consoleURL: URL(string: url), consoleLabel: label) }
        switch self {
        case .cloudflareR2: return guide(["Open R2 in the Cloudflare dashboard and create a bucket.", "Copy your Account ID from the R2 overview page.", "Choose Manage API tokens, then create a token with Object Read & Write limited to that bucket.", "Paste the Account ID, Access Key ID and Secret Access Key here. You can also paste the full endpoint URL."], "https://dash.cloudflare.com/?to=/:account/r2/overview", "Open Cloudflare R2")
        case .backblazeB2: return guide(["Create a private bucket in Backblaze B2.", "Open Application Keys and add a key restricted to that bucket.", "Copy the keyID and applicationKey now; the key is shown only once.", "Paste them here with the bucket name."], "https://secure.backblaze.com/b2_buckets.htm", "Open Backblaze B2")
        case .idriveE2: return guide(["Create a bucket in the IDrive e2 dashboard.", "Open Access Keys and create a key for it.", "Copy the endpoint listed for your bucket's region.", "Paste the endpoint, Access Key ID and Secret Access Key here."], "https://app.idrivee2.com/", "Open IDrive e2")
        case .s3: return guide(["Create a private bucket in the S3 console.", "In IAM create a user limited to that bucket (list, get, put, delete).", "Create an access key for that user and copy both values.", "Paste them here with the bucket's region."], "https://console.aws.amazon.com/s3/", "Open AWS S3")
        case .gcs: return guide(["Create a bucket in Google Cloud Storage.", "Create a service account and grant it Storage Object User on that bucket only.", "Add a JSON key to the service account and download it.", "Choose the downloaded file here. Keep it out of any repository."], "https://console.cloud.google.com/storage/browser", "Open Google Cloud Storage")
        case .azureBlob: return guide(["Create a storage account and a container.", "Open the container's Shared access tokens.", "Generate a SAS with the permissions you need and a sensible expiry.", "Paste the full SAS URL here."], "https://portal.azure.com/#browse/Microsoft.Storage%2FStorageAccounts", "Open Azure Storage")
        case .s3Compatible: return guide(["Create a bucket and an access key in your provider's console.", "Copy the S3 endpoint URL and region.", "Paste the endpoint, keys and region here."], "", "")
        case .googleDrive: return guide(["Choose Sign in with Google on the last step.", "Pick the account for this space in your browser."], "", "")
        case .iCloud: return guide(["Apple sign-in and two-factor opens in Terminal on the last step."], "", "")
        case .other: return nil
        }
    }
}

enum AccessMode: String, Codable { case archive, live }

struct StorageUsage: Codable, Equatable {
    var usedBytes: Int64
    var totalBytes: Int64?
    var objects: Int64?
    var updated: Date
    // True when the provider answered but does not report a quota for this space.
    var unsupported: Bool?
    static func unreported(now: Date = Date()) -> StorageUsage { StorageUsage(usedBytes: 0, totalBytes: nil, objects: nil, updated: now, unsupported: true) }
    var isReported: Bool { unsupported != true }
}

enum QuotaLevel { case unlimited, ok, warning, exceeded }

// Pure usage-versus-allowance calculation so the dashboard and tests share one definition.
struct QuotaStatus: Equatable {
    static let warningFraction = 0.8
    let used: Int64
    let limit: Int64?
    var remaining: Int64? { limit.map { max($0 - used, 0) } }
    var overage: Int64 { limit.map { max(used - $0, 0) } ?? 0 }
    var fraction: Double? { limit.flatMap { $0 > 0 ? min(Double(used) / Double($0), 1) : nil } }
    var level: QuotaLevel {
        guard let limit, limit > 0 else { return .unlimited }
        if used >= limit { return .exceeded }
        return Double(used) / Double(limit) >= Self.warningFraction ? .warning : .ok
    }
    init(used: Int64, limit: Int64?) { self.used = max(used, 0); self.limit = limit }
}

extension StorageUsage {
    // Decodes `rclone size --json` ({"count":N,"bytes":N}) and `rclone about --json` ({"total","used","free"}).
    static func fromSize(_ data: Data, now: Date = Date()) -> StorageUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bytes = (object["bytes"] as? NSNumber)?.int64Value else { return nil }
        return StorageUsage(usedBytes: bytes, totalBytes: nil, objects: (object["count"] as? NSNumber)?.int64Value, updated: now, unsupported: nil)
    }
    static func fromAbout(_ data: Data, now: Date = Date()) -> StorageUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let total = (object["total"] as? NSNumber)?.int64Value
        var used = (object["used"] as? NSNumber)?.int64Value
        if used == nil, let total, let free = (object["free"] as? NSNumber)?.int64Value { used = total - free }
        guard let used else { return nil }
        return StorageUsage(usedBytes: used, totalBytes: total, objects: nil, updated: now, unsupported: nil)
    }
}

struct UsageStore {
    let home: URL
    var url: URL { Storage.support(home: home).appendingPathComponent("usage.json") }
    func load() -> [String: StorageUsage] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: StorageUsage].self, from: Data(contentsOf: url))) ?? [:]
    }
    func save(_ items: [String: StorageUsage]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

struct Storage: Codable, Identifiable, Hashable {
    let id: String
    let provider: Provider
    var title: String
    let remote: String
    let backend: String
    var root: String
    var directory: String
    let cacheKey: String
    let port: Int
    let ownConfig: Bool
    var autoMount: Bool
    var readOnly: Bool
    var mode: AccessMode
    static let googleDrive = Storage(id: "googleDrive", provider: .googleDrive, title: "Google Drive", remote: "cloudshelf-google", backend: "drive", root: "", directory: "Google Drive", cacheKey: "googleDrive", port: 55731, ownConfig: false, autoMount: true, readOnly: false, mode: .live)
    static let iCloud = Storage(id: "iCloud", provider: .iCloud, title: "iCloud Drive", remote: "cloudshelf-icloud", backend: "iclouddrive", root: "", directory: "iCloud Drive", cacheKey: "iCloud", port: 55732, ownConfig: false, autoMount: true, readOnly: false, mode: .live)
    static let legacy: [Storage] = [.googleDrive, .iCloud]
    enum CodingKeys: String, CodingKey { case id, provider, title, remote, backend, root, directory, cacheKey, port, ownConfig, autoMount, readOnly, mode }
    func quota(for usage: StorageUsage?) -> QuotaStatus? {
        guard let usage, usage.isReported else { return nil }
        return QuotaStatus(used: usage.usedBytes, limit: usage.totalBytes ?? provider.freeTierBytes)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var symbol: String { provider.symbol }
    var isArchive: Bool { mode == .archive }
    var remotePath: String { remote + ":" + root }
    // Installs made under the earlier "CloudShelf" name keep using their existing folders, so mounts, caches and credentials are never orphaned.
    static func folder(_ base: URL, _ relative: String) -> URL {
        let legacy = base.appendingPathComponent(relative + "/CloudShelf", isDirectory: true)
        let legacyExists = FileManager.default.fileExists(atPath: legacy.path)
        return base.appendingPathComponent(relative + (legacyExists ? "/CloudShelf" : "/OpenShelf"), isDirectory: true)
    }
    static func support(home: URL) -> URL { folder(home, "Library/Application Support") }
    func configURL(home: URL) -> URL { Self.support(home: home).appendingPathComponent("accounts/" + id + ".conf") }
    func agentURL(home: URL) -> URL { Self.support(home: home).appendingPathComponent("agents/" + id + ".plist") }
    func configArguments(home: URL) -> [String] { ownConfig ? ["--config", configURL(home: home).path] : [] }
    // Explicit directory hints avoid Foundation probing a potentially stalled NFS mount.
    func mountPoint(home: URL) -> URL { (FileManager.default.fileExists(atPath: home.appendingPathComponent("CloudShelf").path) ? home.appendingPathComponent("CloudShelf", isDirectory: true) : home.appendingPathComponent("OpenShelf", isDirectory: true)).appendingPathComponent(directory, isDirectory: true) }
    func cache(home: URL) -> URL { Self.folder(home, "Library/Caches").appendingPathComponent(cacheKey) }
    /// Deletes macOS metadata clutter (._* and .DS_Store); mounts cannot filter these at write time.
    func junkCleanupArguments(home: URL) -> [String] {
        ["delete", remotePath, "--include", "._*", "--include", ".DS_Store"] + configArguments(home: home)
    }
    func arguments(home: URL) -> [String] {
        ["nfsmount", remotePath, mountPoint(home: home).path,
         "--addr", "127.0.0.1:0", "--option", "nolocks", "--option", "noappledouble",
         "--cache-dir", cache(home: home).path,
         "--vfs-cache-mode", "full", "--vfs-cache-max-size", "5G",
         "--vfs-cache-min-free-space", "10G", "--vfs-cache-poll-interval", "10s",
         "--vfs-cache-max-age", isArchive ? "72h" : "1h", "--vfs-read-chunk-size", "8M",
         "--vfs-read-chunk-size-limit", "64M", "--buffer-size", "8M",
         "--rc", "--rc-addr", "127.0.0.1:\(port)", "--log-level", "NOTICE"]
         + (isArchive ? ["--dir-cache-time", "30m", "--vfs-read-ahead", "0"] : [])
         + configArguments(home: home) + (readOnly ? ["--read-only"] : [])
    }
    static func make(provider: Provider, title: String, root: String, existing: [Storage], readOnly: Bool, autoMount: Bool, remote: String? = nil, backend: String? = nil, archive: Bool? = nil) throws -> Storage {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.contains("/"), !label.contains(":"), !label.contains(where: { $0.isNewline }) else { throw StorageError.invalidName }
        guard !root.contains(where: { $0.isNewline }), !root.split(separator: "/").contains("..") else { throw StorageError.invalidRoot }
        let id = UUID().uuidString.lowercased()
        guard let port = (55733...65000).first(where: { value in !existing.contains(where: { $0.port == value }) }) else { throw StorageError.noPort }
        return Storage(id: id, provider: provider, title: label, remote: remote ?? "openshelf-" + id, backend: backend ?? provider.backend, root: root.trimmingCharacters(in: CharacterSet(charactersIn: "/")), directory: label + " · " + String(id.prefix(8)), cacheKey: id, port: port, ownConfig: remote == nil, autoMount: autoMount, readOnly: readOnly, mode: (archive ?? provider.prefersArchive) ? AccessMode.archive : AccessMode.live)
    }
}

extension Storage {
    /// Returns a copy with edited details. Identity, ports, caches and credentials stay the same.
    func updating(title newTitle: String, root newRoot: String, readOnly: Bool, autoMount: Bool, mode: AccessMode, existing: [Storage]) throws -> Storage {
        let label = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.contains("/"), !label.contains(":"), !label.contains(where: { $0.isNewline }) else { throw StorageError.invalidName }
        guard !newRoot.contains(where: { $0.isNewline }), !newRoot.split(separator: "/").contains("..") else { throw StorageError.invalidRoot }
        let cleanRoot = newRoot.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider.isObjectStorage && cleanRoot.isEmpty { throw StorageError.invalidRoot }
        var copy = self
        copy.title = label
        copy.root = cleanRoot
        copy.readOnly = readOnly
        copy.autoMount = autoMount
        copy.mode = provider.prefersArchive ? mode : .live
        // The two built-in accounts keep their fixed Finder folder names.
        if !Storage.legacy.contains(where: { $0.id == id }) { copy.directory = label + " · " + String(id.prefix(8)) }
        if copy.directory != directory, existing.contains(where: { $0.id != id && $0.directory == copy.directory }) { throw StorageError.invalidName }
        return copy
    }
    // Manifests written before archive mode existed gain a mode without touching other fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(Provider.self, forKey: .provider)
        title = try c.decode(String.self, forKey: .title)
        remote = try c.decode(String.self, forKey: .remote)
        backend = try c.decode(String.self, forKey: .backend)
        root = try c.decode(String.self, forKey: .root)
        directory = try c.decode(String.self, forKey: .directory)
        cacheKey = try c.decode(String.self, forKey: .cacheKey)
        port = try c.decode(Int.self, forKey: .port)
        ownConfig = try c.decode(Bool.self, forKey: .ownConfig)
        autoMount = try c.decode(Bool.self, forKey: .autoMount)
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        mode = try c.decodeIfPresent(AccessMode.self, forKey: .mode) ?? (provider.prefersArchive ? .archive : .live)
    }
}

enum EndpointInput {
    // Accepts a bare Cloudflare account ID or the full R2 endpoint URL and returns the account ID.
    static func r2AccountID(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: text)?.host ?? text.replacingOccurrences(of: "https://", with: "").split(separator: "/").first.map(String.init) ?? text
        let id = host.hasSuffix(".r2.cloudflarestorage.com") ? String(host.dropLast(".r2.cloudflarestorage.com".count)) : host
        return id.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil ? id : nil
    }
    // Adds https:// when a provider's endpoint host was pasted without a scheme.
    static func https(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("://") ? text : "https://" + text
    }
}

enum StorageError: LocalizedError {
    case invalidName, invalidRoot, noPort, invalidManifest, busy
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Choose a name of 1–80 characters without slashes, colons, or line breaks."
        case .invalidRoot: return "Use a folder, bucket, or container path without parent traversal or line breaks."
        case .busy: return "Disconnect this space before editing it."
        case .noPort: return "No free account control endpoint is available."
        case .invalidManifest: return "Saved connections could not be loaded safely. Your cloud files and credentials have not been changed."
        }
    }
}

struct ConnectionStore {
    let home: URL
    var url: URL { Storage.support(home: home).appendingPathComponent("connections.json") }
    func load() throws -> [Storage] {
        guard FileManager.default.fileExists(atPath: url.path) else { try save(Storage.legacy); return Storage.legacy }
        let items = try JSONDecoder().decode([Storage].self, from: Data(contentsOf: url))
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.directory)).count == items.count,
              Set(items.map(\.cacheKey)).count == items.count,
              Set(items.map(\.port)).count == items.count,
              items.allSatisfy({ item in
                  [item.id, item.directory, item.cacheKey].allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains(where: { $0.isNewline }) }
                    && item.remote.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
                    && (1024...65535).contains(item.port) && !item.root.contains(where: { $0.isNewline })
                    && !item.root.split(separator: "/").contains("..")
              }) else { throw StorageError.invalidManifest }
        return items
    }
    func save(_ items: [Storage]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Each mount runs as a per-user launchd job so it keeps running (and finishing uploads)
// while OpenShelf is quit or replaced by a newer version.
enum MountAgent {
    static let prefix = "org.openshelf.mount."
    static func label(for storage: Storage) -> String { prefix + storage.id }
    static func domain() -> String { "gui/\(getuid())" }
    static func plist(label: String, executable: String, arguments: [String], password: String) throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "EnvironmentVariables": ["RCLONE_RC_USER": "openshelf", "RCLONE_RC_PASS": password],
            "RunAtLoad": true,
            "KeepAlive": false,
            // Allow time to flush cached writes if the job is asked to stop.
            "ExitTimeOut": 120,
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }
    static func password(in plist: Data) -> String? {
        let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        return (object?["EnvironmentVariables"] as? [String: String])?["RCLONE_RC_PASS"]
    }
    // Parses `launchctl list` into [label: isRunning] for OpenShelf jobs only.
    static func parseList(_ output: String) -> [String: Bool] {
        var jobs: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count >= 3, columns[2].hasPrefix(prefix) else { continue }
            jobs[String(columns[2])] = columns[0] != "-"
        }
        return jobs
    }
}

struct CacheActivity: Decodable {
    let diskCache: DiskCache
    let inUse: Int
    struct DiskCache: Decodable {
        let bytesUsed: Int64
        let uploadsInProgress: Int
        let uploadsQueued: Int
        let erroredFiles: Int
        let outOfSpace: Bool
    }
    var canUnmount: Bool {
        diskCache.uploadsInProgress == 0 && diskCache.uploadsQueued == 0
            && diskCache.erroredFiles == 0 && !diskCache.outOfSpace
    }
}

struct DiskSpace {
    static let reserveBytes: Int64 = 10 * 1024 * 1024 * 1024
    let freeBytes: Int64?
    var canStartMount: Bool { freeBytes.map { $0 >= Self.reserveBytes } ?? false }
    var warning: String? {
        guard let freeBytes else { return "Cannot check free disk space. New drive mounts are paused." }
        guard !canStartMount else { return nil }
        return "Low disk space: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free. New mounts are paused below the 10 GiB reserve. Close files and free space; active files and uploads can still use disk."
    }
}

// Retry saved connections when login networking becomes available. Manual disconnect
// pauses retries until the next launch or an explicit Open drive action.
struct AutoMountPolicy {
    static func shouldAttempt(configured: Bool, mounted: Bool, running: Bool, busy: Bool,
                              paused: Bool, lastAttempt: Date?, now: Date) -> Bool {
        configured && !mounted && !running && !busy && !paused
            && (lastAttempt.map { now.timeIntervalSince($0) >= 60 } ?? true)
    }
}

struct GoogleAuthorization {
    static func token(from output: Data) throws -> String {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: "--->\n"), let end = text.range(of: "\n<---End paste", range: start.upperBound..<text.endIndex) else { throw CocoaError(.coderReadCorrupt) }
        let token = String(text[start.upperBound..<end.lowerBound])
        guard let json = try JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any], json["access_token"] as? String != nil else { throw CocoaError(.coderReadCorrupt) }
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
}


// Moves folders created under the earlier "CloudShelf" name to "OpenShelf" once nothing is mounted from them.
enum LegacyMigration {
    static let locations = ["", "Library/Application Support", "Library/Caches", "Library/Logs"]
    static func activeMountPaths() -> [String] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            guard let on = line.range(of: " on "), let end = line.range(of: " (", range: on.upperBound..<line.endIndex) else { return nil }
            return String(line[on.upperBound..<end.lowerBound])
        }
    }
    /// Returns the number of folders moved. Skips any location that still has a mount inside it or already has a new-name folder.
    @discardableResult
    static func run(home: URL, mountPaths: [String] = activeMountPaths()) -> Int {
        let fm = FileManager.default
        var moved = 0
        for relative in locations {
            let base = relative.isEmpty ? home : home.appendingPathComponent(relative, isDirectory: true)
            let old = base.appendingPathComponent("CloudShelf", isDirectory: true)
            let new = base.appendingPathComponent("OpenShelf", isDirectory: true)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            if mountPaths.contains(where: { $0 == old.path || $0.hasPrefix(old.path + "/") }) { continue }
            if (try? fm.moveItem(at: old, to: new)) != nil { moved += 1 }
        }
        return moved
    }
}
