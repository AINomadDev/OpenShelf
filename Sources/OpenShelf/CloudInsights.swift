import Foundation

// Provider-reported usage and request counts. Pure parsing and cost maths; networking lives in DriveManager.

/// Month-to-date numbers from Cloudflare's GraphQL Analytics API (needs an API token with Account Analytics: Read).
struct R2Insight: Codable, Equatable {
    var storageBytes: Int64
    var objects: Int64
    var classA: Int64
    var classB: Int64
    var updated: Date

    static let freeClassA: Int64 = 1_000_000
    static let freeClassB: Int64 = 10_000_000
    static let classAPerMillion = 4.50
    static let classBPerMillion = 0.36

    // Cloudflare rounds billable operations up to the next million.
    private static func billableMillions(_ count: Int64, free: Int64) -> Double { Double(((max(count - free, 0)) + 999_999) / 1_000_000) }
    /// Request charges after the free allowance. Standard storage class only.
    var requestCost: Double {
        Self.billableMillions(classA, free: Self.freeClassA) * Self.classAPerMillion
            + Self.billableMillions(classB, free: Self.freeClassB) * Self.classBPerMillion
    }
    var classAFraction: Double { Double(classA) / Double(Self.freeClassA) }
    var classBFraction: Double { Double(classB) / Double(Self.freeClassB) }
}

enum R2Analytics {
    static let endpoint = URL(string: "https://api.cloudflare.com/client/v4/graphql")!
    static let classA: Set<String> = ["ListBuckets", "PutBucket", "ListObjects", "ListObjectsV2", "PutObject", "CopyObject", "CompleteMultipartUpload", "CreateMultipartUpload", "LifecycleStorageTierTransition", "ListMultipartUploads", "UploadPart", "UploadPartCopy", "ListParts", "PutBucketEncryption", "PutBucketCors", "PutBucketLifecycleConfiguration"]
    static let classB: Set<String> = ["HeadBucket", "HeadObject", "GetObject", "UsageSummary", "GetBucketEncryption", "GetBucketLocation", "GetBucketCors", "GetBucketLifecycleConfiguration"]

    static let query = """
    query R2($accountTag: string!, $start: Time, $end: Time, $bucket: string) {
      viewer { accounts(filter: { accountTag: $accountTag }) {
        r2OperationsAdaptiveGroups(limit: 10000, filter: { datetime_geq: $start, datetime_leq: $end, bucketName: $bucket }) {
          sum { requests } dimensions { actionType }
        }
        r2StorageAdaptiveGroups(limit: 1, filter: { datetime_geq: $start, datetime_leq: $end, bucketName: $bucket }, orderBy: [datetime_DESC]) {
          max { objectCount payloadSize metadataSize } dimensions { datetime }
        }
      } }
    }
    """

    /// The bucket is the first path component of a space's root.
    static func bucket(of root: String) -> String? {
        let name = root.split(separator: "/").first.map(String.init)
        return name?.isEmpty == false ? name : nil
    }

    static func request(token: String, account: String, bucket: String, now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> URLRequest {
        var utc = calendar; utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
        let formatter = ISO8601DateFormatter()
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["query": query, "variables": ["accountTag": account, "start": formatter.string(from: monthStart), "end": formatter.string(from: now), "bucket": bucket]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Nil when the API reports errors (for example an under-scoped token) or the shape is unexpected.
    static func parse(_ data: Data, now: Date = Date()) -> R2Insight? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { return nil }
        guard let accounts = ((root["data"] as? [String: Any])?["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]],
              let account = accounts.first else { return nil }
        var a: Int64 = 0, b: Int64 = 0
        for group in account["r2OperationsAdaptiveGroups"] as? [[String: Any]] ?? [] {
            let name = (group["dimensions"] as? [String: Any])?["actionType"] as? String ?? ""
            let count = ((group["sum"] as? [String: Any])?["requests"] as? NSNumber)?.int64Value ?? 0
            if classA.contains(name) { a += count } else if classB.contains(name) { b += count }
        }
        let storage = ((account["r2StorageAdaptiveGroups"] as? [[String: Any]])?.first?["max"] as? [String: Any]) ?? [:]
        let payload = (storage["payloadSize"] as? NSNumber)?.int64Value ?? 0
        let metadata = (storage["metadataSize"] as? NSNumber)?.int64Value ?? 0
        let objects = (storage["objectCount"] as? NSNumber)?.int64Value ?? 0
        return R2Insight(storageBytes: payload + metadata, objects: objects, classA: a, classB: b, updated: now)
    }

    /// Handles jurisdiction endpoints such as `<id>.eu.r2.cloudflarestorage.com` and `<id>.fedramp.r2...` too.
    static func accountID(fromHost host: String?) -> String? {
        guard let host, host.hasSuffix(".r2.cloudflarestorage.com") else { return nil }
        let id = host.dropLast(".r2.cloudflarestorage.com".count).split(separator: ".").first.map(String.init)
        return id?.isEmpty == false ? id : nil
    }

    /// Turns a failed analytics response into a message that says what to fix, instead of a generic "rejected".
    static func failureReason(status: Int?, data: Data?) -> String {
        guard let status else { return "Could not reach Cloudflare. Check your internet connection." }
        var messages: [String] = []
        if let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["errors"] {
                for item in root[key] as? [[String: Any]] ?? [] { if let m = item["message"] as? String { messages.append(m) } }
            }
        }
        let detail = messages.first.map { " Cloudflare said: \($0)" } ?? ""
        let lower = detail.lowercased()
        if status == 401 || lower.contains("authenticat") || lower.contains("invalid") && lower.contains("token") {
            return "Cloudflare did not accept this token (HTTP \(status)). Paste the token value itself, not the Token ID, with no spaces." + detail
        }
        if status == 403 || lower.contains("not authorized") || lower.contains("permission") || lower.contains("access") {
            return "The token is valid but lacks access. Give it Account → Account Analytics → Read and set Account Resources to include this account (not a single zone)." + detail
        }
        if lower.contains("does not have access to the path") || lower.contains("unknown field") {
            return "Cloudflare changed the analytics schema or this account has no R2 analytics yet." + detail
        }
        if status == 200, !messages.isEmpty { return "Cloudflare could not run the usage query." + detail }
        if status == 200 { return "Cloudflare returned no data for this bucket yet. Analytics can lag by several minutes." + detail }
        return "Cloudflare analytics failed (HTTP \(status))." + detail
    }
}

struct InsightStore {
    let home: URL
    var url: URL { Storage.support(home: home).appendingPathComponent("insights.json") }
    func load() -> [String: R2Insight] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: R2Insight].self, from: Data(contentsOf: url))) ?? [:]
    }
    func save(_ items: [String: R2Insight]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

extension Storage {
    /// Cloudflare API token, kept apart from the S3 keys in its own owner-only file.
    /// Token shared by every space in one Cloudflare account.
    static func accountTokenURL(home: URL, account: String) -> URL { support(home: home).appendingPathComponent("accounts/cf-" + account + ".cftoken") }
    func apiTokenURL(home: URL) -> URL { Self.support(home: home).appendingPathComponent("accounts/" + id + ".cftoken") }
}

enum FreeTierPool {
    /// The free allowance is per provider account, so spaces in one account share it. Each space's share of the pooled bill is proportional to its size.
    static func costs(_ items: [(id: String, provider: Provider, pool: String?, bytes: Int64)]) -> [String: Double] {
        var result: [String: Double] = [:]
        var groups: [String: [(id: String, provider: Provider, bytes: Int64)]] = [:]
        for item in items {
            guard item.provider.pricing != nil else { continue }
            if let pool = item.pool { groups[item.provider.rawValue + "|" + pool, default: []].append((item.id, item.provider, item.bytes)) }
            else { result[item.id] = item.provider.pricing!.monthlyStorageCost(usedBytes: item.bytes) }
        }
        for members in groups.values {
            let total = members.reduce(Int64(0)) { $0 + $1.bytes }
            let bill = members[0].provider.pricing!.monthlyStorageCost(usedBytes: total)
            for member in members { result[member.id] = total > 0 ? bill * Double(member.bytes) / Double(total) : 0 }
        }
        return result
    }
}

/// Alerts fire once when a level worsens and re-arm after it improves, so a refresh every few hours does not re-notify.
enum AlertTracker {
    static func shouldNotify(previous: Int, current: Int) -> Bool { current > previous }
    static func update(_ state: [String: Int], key: String, level: Int) -> (state: [String: Int], notify: Bool) {
        var next = state
        let notify = shouldNotify(previous: state[key] ?? 0, current: level)
        if level == 0 { next[key] = nil } else { next[key] = level }
        return (next, notify)
    }
}

enum AlertSeverity { static let none = 0, warning = 1, critical = 2 }

/// Everything on the shelf combined: data stored, fixed account quotas and what is left of pay-as-you-go free tiers.
struct ShelfTotals: Equatable {
    var storedBytes: Int64 = 0
    var quotaUsed: Int64 = 0
    var quotaCapacity: Int64 = 0
    var quotaAccounts = 0
    var freeTierUsed: Int64 = 0
    var freeTierCapacity: Int64 = 0
    var quotaLeft: Int64 { max(0, quotaCapacity - quotaUsed) }
    var freeTierLeft: Int64 { max(0, freeTierCapacity - freeTierUsed) }

    /// Spaces sharing one account report the same quota, so identical quota readings count once.
    static func make(_ items: [(id: String, provider: Provider, pool: String?, usage: StorageUsage)]) -> ShelfTotals {
        var totals = ShelfTotals()
        var seenQuota = Set<String>()
        var freeGroups: [String: Int64] = [:]
        for item in items {
            let usage = item.usage
            if let total = usage.totalBytes {
                guard seenQuota.insert("\(item.provider.rawValue)|\(total)|\(usage.usedBytes)").inserted else { continue }
                totals.storedBytes += usage.usedBytes
                totals.quotaUsed += usage.usedBytes
                totals.quotaCapacity += total
                totals.quotaAccounts += 1
            } else {
                totals.storedBytes += usage.usedBytes
                if item.provider.freeTierBytes != nil { freeGroups[item.provider.rawValue + "|" + (item.pool ?? item.id), default: 0] += usage.usedBytes }
            }
        }
        for (key, used) in freeGroups {
            let provider = Provider(rawValue: String(key.split(separator: "|")[0]))
            totals.freeTierUsed += used
            totals.freeTierCapacity += provider?.freeTierBytes ?? 0
        }
        return totals
    }
}
