import Foundation

// Pure cost, budget and growth logic. UI-free so the core checks compile it standalone.

extension Provider {
    /// Numeric internet egress price per GB for providers that bill it; nil when egress is free or plan-dependent.
    var egressPerGB: Double? {
        switch self {
        case .s3: return 0.09
        case .gcs: return 0.12
        case .azureBlob: return 0.087
        default: return nil
        }
    }
}

enum RestoreCost {
    /// Estimated cost to download `bytes` from a space. Nil when the provider does not bill egress per GB.
    static func estimate(bytes: Int64, provider: Provider) -> Double? {
        guard let rate = provider.egressPerGB else { return nil }
        return Double(bytes) / 1_000_000_000 * rate
    }
}

struct BudgetStore {
    let home: URL
    var url: URL { Storage.support(home: home).appendingPathComponent("budgets.json") }
    func load() -> [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))) ?? [:]
    }
    func save(_ items: [String: Double]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

enum BudgetLevel: Equatable { case none, ok, nearing, exceeded }

enum Budget {
    static func level(cost: Double, budget: Double?) -> BudgetLevel {
        guard let budget, budget > 0 else { return .none }
        if cost > budget { return .exceeded }
        return cost >= budget * 0.8 ? .nearing : .ok
    }
}

struct UsageSample: Codable, Equatable {
    var date: Date
    var bytes: Int64
}

struct HistoryStore {
    let home: URL
    var url: URL { Storage.support(home: home).appendingPathComponent("history.json") }
    func load() -> [String: [UsageSample]] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [UsageSample]].self, from: Data(contentsOf: url))) ?? [:]
    }
    func save(_ items: [String: [UsageSample]]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

enum UsageHistory {
    static let keepDays = 400

    /// One sample per calendar day (the latest wins), trimmed to roughly a year.
    static func record(_ bytes: Int64, at date: Date, into samples: [UsageSample], calendar: Calendar = .current) -> [UsageSample] {
        var result = samples.filter { !calendar.isDate($0.date, inSameDayAs: date) }
        result.append(UsageSample(date: date, bytes: bytes))
        result.sort { $0.date < $1.date }
        let cutoff = date.addingTimeInterval(-Double(keepDays) * 86_400)
        return result.filter { $0.date >= cutoff }
    }

    /// Bytes per day over the sampled span; needs at least two samples a day apart.
    static func growthPerDay(_ samples: [UsageSample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 1 else { return nil }
        return Double(last.bytes - first.bytes) / days
    }

    /// Whole days until `limit` is reached at the current growth rate. 0 when already over; nil when not growing.
    static func daysUntil(limit: Int64, samples: [UsageSample]) -> Int? {
        guard let last = samples.last else { return nil }
        if last.bytes >= limit { return 0 }
        guard let rate = growthPerDay(samples), rate > 0 else { return nil }
        return Int((Double(limit - last.bytes) / rate).rounded(.up))
    }
}

enum CostSummary {
    /// Estimated monthly storage bill across all spaces that have list pricing. Free tiers are applied per space, which can overstate the bill when several spaces share one provider account.
    static func monthlyTotal(_ items: [(provider: Provider, usedBytes: Int64)]) -> Double {
        items.reduce(0) { $0 + ($1.provider.pricing?.monthlyStorageCost(usedBytes: $1.usedBytes) ?? 0) }
    }
}

// Direct rclone transfers: they upload or compare in the background without going through a Finder mount.
extension Storage {
    static let archiveExcludes = ["._*", ".DS_Store", ".Trash/**", "node_modules/**", ".git/objects/**"]

    /// Copies a local folder into this space under `subfolder`. Copy never deletes anything at the destination.
    func archiveCopyArguments(source: URL, subfolder: String, home: URL) -> [String] {
        ["copy", source.path, destination(subfolder)]
            + Self.archiveExcludes.flatMap { ["--exclude", $0] }
            + ["--transfers", "4", "--checkers", "8", "--stats", "10s", "--stats-one-line", "--log-level", "NOTICE"]
            + configArguments(home: home)
    }
    /// Compares a local folder with its archived copy by size and checksum, without downloading file contents when hashes are available.
    func verifyArguments(source: URL, subfolder: String, home: URL) -> [String] {
        ["check", source.path, destination(subfolder), "--one-way"]
            + Self.archiveExcludes.flatMap { ["--exclude", $0] }
            + configArguments(home: home)
    }
    private func destination(_ subfolder: String) -> String {
        let clean = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return clean.isEmpty ? remotePath : remotePath.hasSuffix(":") || remotePath.hasSuffix("/") ? remotePath + clean : remotePath + "/" + clean
    }
}

enum CredentialHealth {
    /// Expiry date (`se=` parameter) of an Azure SAS URL or token.
    static func sasExpiry(_ sas: String) -> Date? {
        guard let query = sas.split(separator: "?", maxSplits: 1).last else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "se", let value = String(parts[1]).removingPercentEncoding else { continue }
            let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return plain.date(from: value) ?? fractional.date(from: value)
        }
        return nil
    }
    /// Reads one key from an rclone INI config.
    static func configValue(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }
    static func warning(expiry: Date?, now: Date = Date()) -> String? {
        guard let expiry else { return nil }
        let days = Int(expiry.timeIntervalSince(now) / 86_400)
        if expiry <= now { return "The access token for this space has expired. Edit the space to paste a new one." }
        return days <= 14 ? "The access token for this space expires in \(max(days, 1)) day\(days <= 1 ? "" : "s")." : nil
    }
}
