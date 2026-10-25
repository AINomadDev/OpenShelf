import SwiftUI
import AppKit
import ServiceManagement

struct CommandResult {
    let code: Int32
    let output: Data
}

// Short diagnostic commands never block the main thread; interactive authentication uses Terminal.
func runCommand(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeoutSeconds: TimeInterval = 25, suppliedProcess: Process? = nil) async throws -> CommandResult {
    try await Task.detached {
        let process = suppliedProcess ?? Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return CommandResult(code: process.terminationStatus, output: output)
    }.value
}

@MainActor
final class DriveManager: ObservableObject {
    @Published var connections: [Storage] = []
    @Published var showingAddStorage = false
    @Published var showingActivity = false
    @Published var searchText = ""
    @Published var providerFilter: Provider?
    @Published var mountedOnly = false
    var visibleConnections: [Storage] {
        connections.filter { storage in
            (providerFilter == nil || storage.provider == providerFilter)
                && (!mountedOnly || mounted.contains(storage))
                && (searchText.isEmpty || ([storage.title, storage.provider.title, storage.root, storage.note, identities[storage.id]?.email ?? "", identities[storage.id]?.name ?? "", identities[storage.id]?.detail ?? ""] + storage.tags).contains { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }
    func showAllSpaces() { searchText = ""; providerFilter = nil; mountedOnly = false }
    func copyPath(_ storage: Storage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(storage.mountPoint(home: home).path, forType: .string)
    }
    @Published var spaceToRemove: Storage?
    @Published var spaceToEdit: Storage?
    @Published var archiveToOpen: Storage?
    private var store: ConnectionStore { ConnectionStore(home: home) }
    private var usageStore: UsageStore { UsageStore(home: home) }
    private var identityStore: IdentityStore { IdentityStore(home: home) }
    private var budgetStore: BudgetStore { BudgetStore(home: home) }
    private var historyStore: HistoryStore { HistoryStore(home: home) }
    init() {
        if Self.isPreview { loadPreviewData(); return }
        LegacyMigration.run(home: home)
        do { connections = try store.load() }
        catch { notice = error.localizedDescription }
        usage = usageStore.load()
        identities = identityStore.load()
        budgets = budgetStore.load()
        history = historyStore.load()
    }
    private func recordHistory() {
        guard !Self.isPreview else { return }
        var changed = false
        for (id, value) in usage where value.isReported || value.measured == true {
            let samples = history[id] ?? []
            // Skip when today's sample already matches, so refreshes do not rewrite the file.
            if let last = samples.last, Calendar.current.isDateInToday(last.date), last.bytes == value.usedBytes { continue }
            history[id] = UsageHistory.record(value.usedBytes, at: Date(), into: samples)
            changed = true
        }
        if changed { historyStore.save(history) }
    }
    func setBudget(_ value: Double?, for storage: Storage) {
        if let value, value > 0 { budgets[storage.id] = value } else { budgets[storage.id] = nil }
        budgetStore.save(budgets)
    }
    func monthlyCost(_ storage: Storage) -> Double? {
        guard let pricing = storage.provider.pricing, let value = usage[storage.id], value.isReported || value.measured == true else { return nil }
        return pricing.monthlyStorageCost(usedBytes: value.usedBytes)
    }
    var monthlyTotal: Double {
        CostSummary.monthlyTotal(connections.compactMap { storage in
            guard let value = usage[storage.id], value.isReported || value.measured == true else { return nil }
            return (storage.provider, value.usedBytes)
        })
    }
    func budgetLevel(_ storage: Storage) -> BudgetLevel { Budget.level(cost: monthlyCost(storage) ?? 0, budget: budgets[storage.id]) }
    /// Days until a free-tier space passes its allowance at the recent growth rate.
    func daysUntilFreeTier(_ storage: Storage) -> Int? {
        guard let limit = storage.provider.freeTierBytes, usage[storage.id]?.totalBytes == nil else { return nil }
        return UsageHistory.daysUntil(limit: limit, samples: history[storage.id] ?? [])
    }
    func restoreCost(_ storage: Storage) -> Double? {
        guard let bytes = usage[storage.id]?.usedBytes, bytes > 0 else { return nil }
        return RestoreCost.estimate(bytes: bytes, provider: storage.provider)
    }
    func add(_ storage: Storage) throws {
        let updated = connections + [storage]
        try store.save(updated)
        connections = updated
    }
    func remove(_ storage: Storage) {
        guard !mounted.contains(storage), !isRunning(storage), !busy.contains(storage) else {
            notice = "Disconnect this space before removing it."
            return
        }
        let updated = connections.filter { $0 != storage }
        do {
            try store.save(updated)
            connections = updated
            statuses[storage] = nil
            configured.remove(storage)
            autoMountPaused.remove(storage)
            lastAutoAttempt[storage] = nil
            usage[storage.id] = nil
            usageStore.save(usage)
        } catch { notice = "Could not remove the saved space." }
    }
    func setMode(_ storage: Storage, _ mode: AccessMode) {
        guard let index = connections.firstIndex(of: storage) else { return }
        var updated = connections
        updated[index].mode = mode
        do {
            try store.save(updated); connections = updated
            if mounted.contains(storage) { statuses[storage] = "Mode applies the next time this drive is mounted." }
        } catch { notice = "Could not save the access mode." }
    }
    var canEdit: (Storage) -> Bool { { [self] in !mounted.contains($0) && !isRunning($0) && !busy.contains($0) } }
    /// Saves tags, note, auto-mount and archive mode, which are safe to change while a drive is mounted.
    func applyLiveEdit(_ old: Storage, with new: Storage) throws {
        guard let index = connections.firstIndex(of: old) else { throw StorageError.busy }
        var updated = connections
        updated[index] = new
        try store.save(updated)
        connections = updated
        if old.mode != new.mode, mounted.contains(old) { statuses[new] = "Mode applies the next time this drive is mounted." }
    }
    func replace(_ old: Storage, with new: Storage) throws {
        guard canEdit(old), let index = connections.firstIndex(of: old) else { throw StorageError.busy }
        var updated = connections
        updated[index] = new
        try store.save(updated)
        connections = updated
        if old.directory != new.directory {
            let oldFolder = old.mountPoint(home: home)
            if (try? FileManager.default.contentsOfDirectory(atPath: oldFolder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: oldFolder) }
        }
        if old.root != new.root || old.remote != new.remote {
            usage[new.id] = nil
            usageStore.save(usage)
            forceUsage.insert(new.id)
        }
        statuses[new] = nil
    }
    func setAutoMount(_ storage: Storage, enabled: Bool) {
        guard let index = connections.firstIndex(of: storage) else { return }
        var updated = connections
        updated[index].autoMount = enabled
        do { try store.save(updated); connections = updated }
        catch { notice = "Could not save the startup preference." }
    }
    @Published var statuses: [Storage: String] = [:]
    @Published var configured: Set<Storage> = []
    @Published var mounted: Set<Storage> = []
    @Published var busy: Set<Storage> = []
    @Published var activity: [Storage: CacheActivity] = [:]
    @Published var usage: [String: StorageUsage] = [:] { didSet { recordHistory() } }
    @Published var budgets: [String: Double] = [:]
    @Published var history: [String: [UsageSample]] = [:]
    @Published var identities: [String: AccountIdentity] = [:]
    private var identityRefreshing: Set<String> = []
    private var lastIdentityAttempt: [String: Date] = [:]
    @Published var usageRefreshing: Set<String> = []
    @Published var refreshing = false
    @Published var showingGuide = false
    @Published var notice: String?
    @Published var diskSpace = DiskSpace(freeBytes: nil)
    @Published var loginStatus = "Checking login startup…"
    private var forceUsage: Set<String> = []
    private var lastUsageAttempt: [String: Date] = [:]
    private var lastConfigCheck: [String: Date] = [:]
    private var autoMountPaused: Set<Storage> = []
    private var lastAutoAttempt: [Storage: Date] = [:]
    @Published private(set) var agents: Set<Storage> = []
    private var started: [Storage: Date] = [:]
    private let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    // Preview mode shows sample data in a scratch home and never starts mounts or reads real configuration.
    static let isPreview = ProcessInfo.processInfo.environment["OPENSHELF_PREVIEW"] == "1"
    private let home = DriveManager.isPreview
        ? FileManager.default.temporaryDirectory.appendingPathComponent("openshelf-preview", isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser
    private var monitor: Task<Void, Never>?
    var authenticationProcess: Process?
    var rclone: URL? {
        let bundled = Bundle.main.url(forResource: "rclone", withExtension: nil)?.path
        return [bundled, "/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]
            .compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
    // Mounts run as independent launchd jobs, so only an in-progress sign-in blocks quitting.
    var blocksQuit: Bool { authenticationProcess?.isRunning == true }
    func isRunning(_ storage: Storage) -> Bool { agents.contains(storage) }
    private func stopAgent(_ storage: Storage) async {
        _ = try? await runCommand(launchctl, ["bootout", MountAgent.domain() + "/" + MountAgent.label(for: storage)])
        try? FileManager.default.removeItem(at: storage.agentURL(home: home))
    }
    // Finds drives started by this or an earlier OpenShelf run, and cleans up jobs that have exited.
    private func syncAgents() async {
        guard let result = try? await runCommand(launchctl, ["list"]), result.code == 0 else { return }
        let jobs = MountAgent.parseList(String(decoding: result.output, as: UTF8.self))
        var live: Set<Storage> = []
        for storage in connections {
            guard let running = jobs[MountAgent.label(for: storage)] else {
                if agents.contains(storage) { handleExit(storage) }
                continue
            }
            if running { live.insert(storage) }
            else {
                await stopAgent(storage)
                handleExit(storage)
            }
        }
        if live != agents { agents = live }
    }
    private func handleExit(_ storage: Storage) {
        agents.remove(storage)
        activity[storage] = nil
        busy.remove(storage)
        statuses[storage] = "Drive stopped. Open its log, then reconnect."
    }
    func logURL(_ storage: Storage) -> URL {
        Storage.folder(home, "Library/Logs").appendingPathComponent("\(storage.id).log")
    }
    func open(_ storage: Storage) { if Self.isPreview { notice = "Preview mode: Finder is not opened."; return }; NSWorkspace.shared.open(storage.mountPoint(home: home)) }
    func showLog(_ storage: Storage) {
        if FileManager.default.fileExists(atPath: logURL(storage).path) { NSWorkspace.shared.open(logURL(storage)) }
        else { notice = "No log yet. A log is created when this drive starts." }
    }
    func startMonitoring() {
        guard monitor == nil, !Self.isPreview else { return }
        // Register once by default; respect later changes made in System Settings.
        if !UserDefaults.standard.bool(forKey: "loginRegistrationAttempted") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginRegistrationAttempted")
            } catch {
                loginStatus = "Login startup needs attention in System Settings."
            }
        }
        updateLoginStatus()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.autoMountSavedConnections()
                self?.refreshStaleUsage()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    private func updateLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Starts automatically at login"
        case .requiresApproval: loginStatus = "Allow OpenShelf in Login Items"
        case .notRegistered: loginStatus = "Login startup is off in System Settings"
        case .notFound: loginStatus = "Login startup unavailable for this installation"
        @unknown default: loginStatus = "Check Login Items in System Settings"
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func autoMountSavedConnections() async {
        for storage in connections {
            guard AutoMountPolicy.shouldAttempt(configured: configured.contains(storage) && storage.autoMount,
                mounted: mounted.contains(storage), running: isRunning(storage),
                busy: busy.contains(storage), paused: autoMountPaused.contains(storage),
                lastAttempt: lastAutoAttempt[storage], now: Date()), diskSpace.canStartMount else { continue }
            lastAutoAttempt[storage] = Date()
            await mount(storage)
        }
    }
    func refresh() async {
        guard !refreshing else { return }
        updateDiskSpace()
        updateLoginStatus()
        refreshing = true
        defer { refreshing = false }
        guard let binary = rclone else { notice = "Storage engine missing. Rebuild using the setup guide."; return }
        var available: Set<Storage> = []
        // Each additional account has its own protected engine configuration.
        // Saved connections rarely change, so only unconfigured ones are re-probed every cycle.
        for storage in connections {
            if configured.contains(storage), let last = lastConfigCheck[storage.id], Date().timeIntervalSince(last) < 60 {
                available.insert(storage)
                continue
            }
            lastConfigCheck[storage.id] = Date()
            let args = ["listremotes", "--json"] + storage.configArguments(home: home)
            if let result = try? await runCommand(binary, args), result.code == 0,
               let remotes = try? JSONDecoder().decode([RemoteSummary].self, from: result.output),
               remotes.contains(where: { $0.name == storage.remote && $0.type == storage.backend }) {
                available.insert(storage)
            }
        }
        configured = available
        await syncAgents()
        guard let result = try? await runCommand(URL(fileURLWithPath: "/sbin/mount"), []), result.code == 0 else { return }
        let table = String(decoding: result.output, as: UTF8.self)
        mounted = Set(connections.filter { table.contains(" on " + $0.mountPoint(home: home).path + " (") })
        for storage in connections where isRunning(storage) {
            if mounted.contains(storage) {
                busy.remove(storage)
                activity[storage] = try? await fetchActivity(storage)
                statuses[storage] = activity[storage] == nil ? "Drive mounted · checking transfer status" : "Available in Finder"
            } else if let date = started[storage], Date().timeIntervalSince(date) > 30 {
                statuses[storage] = "Drive did not mount in time. Open the log, then retry."
                await stopAgent(storage)
                agents.remove(storage)
            }
        }
    }
    // Object stores have no quota API, so usage comes from listing the space (cached; requests are billed).
    private static let objectUsageTTL: TimeInterval = 6 * 3600
    private static let accountUsageTTL: TimeInterval = 1800
    private static let usageRetry: TimeInterval = 900
    private func refreshStaleUsage() {
        refreshIdentities()
        for storage in connections where configured.contains(storage) && !usageRefreshing.contains(storage.id) {
            let ttl = storage.provider.isObjectStorage ? Self.objectUsageTTL : Self.accountUsageTTL
            let fresh = !forceUsage.contains(storage.id) && usage[storage.id].map { Date().timeIntervalSince($0.updated) < ttl } ?? false
            let recentlyTried = lastUsageAttempt[storage.id].map { $0.timeIntervalSinceNow > -Self.usageRetry } ?? false
            if !fresh && !recentlyTried && usageRefreshing.isEmpty { refreshUsage(storage); return }
        }
    }
    /// Uploads a local folder straight to the space (no Finder mount needed). Runs while the app is open.
    func archiveFolder(_ storage: Storage, subfolder: String? = nil) {
        guard !Self.isPreview, !busy.contains(storage), let binary = rclone else { return }
        guard !storage.readOnly else { notice = "\(storage.title) is read-only."; return }
        guard let folder = chooseFolder("Choose a folder to archive to \(storage.title)") else { return }
        let target = subfolder ?? folder.lastPathComponent
        busy.insert(storage)
        notice = "Uploading \(folder.lastPathComponent) to \(storage.title)… You can keep using the app; keep it open until this finishes."
        let arguments = storage.archiveCopyArguments(source: folder, subfolder: target, home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, arguments, timeoutSeconds: 86_400)
            guard let self else { return }
            self.busy.remove(storage)
            if result?.code == 0 {
                self.notice = "Archived \(folder.lastPathComponent) to \(storage.title). Use Verify archive to confirm the copy."
                self.forceUsage.insert(storage.id)
                self.refreshUsage(storage)
            } else {
                self.notice = "The upload did not finish. Check your connection and credentials, then run it again; already uploaded files are skipped."
            }
        }
    }
    /// Compares a local folder with the archived copy by checksum; it never changes either side.
    func verifyArchive(_ storage: Storage) {
        guard !Self.isPreview, !busy.contains(storage), let binary = rclone else { return }
        guard let folder = chooseFolder("Choose the local folder to compare with \(storage.title)") else { return }
        busy.insert(storage)
        notice = "Verifying \(folder.lastPathComponent)…"
        let arguments = storage.verifyArguments(source: folder, subfolder: folder.lastPathComponent, home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, arguments, timeoutSeconds: 86_400)
            guard let self else { return }
            self.busy.remove(storage)
            switch result?.code {
            case 0?: self.notice = "Verified: every file in \(folder.lastPathComponent) is safely stored in \(storage.title)."
            case 1?: self.notice = "Some files in \(folder.lastPathComponent) are missing or differ in \(storage.title). Run Archive folder again."
            default: self.notice = "Could not verify. Check the connection and that the folder was archived under its own name."
            }
        }
    }
    private func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = message; panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func credentialWarning(_ storage: Storage) -> String? {
        guard storage.ownConfig, storage.provider == .azureBlob,
              let text = try? String(contentsOf: storage.configURL(home: home), encoding: .utf8),
              let sas = CredentialHealth.configValue("sas_url", in: text) else { return nil }
        return CredentialHealth.warning(expiry: CredentialHealth.sasExpiry(sas))
    }
    func cleanJunk(_ storage: Storage) {
        guard !Self.isPreview, !busy.contains(storage), let binary = rclone else { return }
        busy.insert(storage)
        let arguments = storage.junkCleanupArguments(home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, arguments, timeoutSeconds: 1800)
            guard let self else { return }
            self.busy.remove(storage)
            if result?.code == 0 {
                self.notice = "Removed ._* and .DS_Store files from \(storage.title)."
                self.forceUsage.insert(storage.id)
                self.refreshUsage(storage)
            } else {
                self.notice = "Could not clean junk files. Check your connection and credentials, then try again."
            }
        }
    }
    /// Lists every file to total a size for providers that report no quota; can take a long time on large drives.
    func measureSize(_ storage: Storage) {
        guard !Self.isPreview, !usageRefreshing.contains(storage.id), let binary = rclone else { return }
        usageRefreshing.insert(storage.id)
        let arguments = ["size", "--json", storage.remotePath] + storage.configArguments(home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, arguments, timeoutSeconds: 3600)
            guard let self else { return }
            self.usageRefreshing.remove(storage.id)
            guard let result, result.code == 0, var value = StorageUsage.fromSize(result.output) else {
                self.notice = "Could not measure the size of \(storage.title). Try again later."
                return
            }
            value.unsupported = true
            value.measured = true
            self.usage[storage.id] = value
            self.usageStore.save(self.usage)
        }
    }
    private func refreshIdentities() {
        guard !Self.isPreview, identityRefreshing.isEmpty, let binary = rclone else { return }
        for storage in connections where configured.contains(storage) {
            let known = identities[storage.id].map { $0.headline != nil && Date().timeIntervalSince($0.updated) < 7 * 86_400 } ?? false
            let tried = lastIdentityAttempt[storage.id].map { $0.timeIntervalSinceNow > -900 } ?? false
            if known || tried { continue }
            lastIdentityAttempt[storage.id] = Date()
            identityRefreshing.insert(storage.id)
            let arguments = ["config", "dump"] + storage.configArguments(home: home)
            Task { [weak self] in
                let result = try? await runCommand(binary, arguments, timeoutSeconds: 30)
                guard let self else { return }
                defer { self.identityRefreshing.remove(storage.id) }
                // The dump holds secrets: it is parsed in memory only and never logged or stored.
                guard let result, result.code == 0,
                      let all = try? JSONSerialization.jsonObject(with: result.output) as? [String: [String: String]],
                      let section = all[storage.remote] else { return }
                var identity = AccountIdentity.from(provider: storage.provider, config: section)
                if storage.provider == .googleDrive, let google = await Self.googleAccount(token: section["token"]) {
                    identity = google.identity
                    if let account = google.usage, self.usage[storage.id]?.isReported != true || self.usage[storage.id]?.accountWide == true {
                        self.usage[storage.id] = account
                        self.usageStore.save(self.usage)
                    }
                }
                guard identity.headline != nil || identity.name != nil else { return }
                self.identities[storage.id] = identity
                self.identityStore.save(self.identities)
            }
            return
        }
    }
    private static func googleAccount(token: String?) async -> (identity: AccountIdentity, usage: StorageUsage?)? {
        guard let token, let object = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any],
              let access = object["access_token"] as? String,
              let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,displayName),storageQuota(limit,usage)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return AccountIdentity.googleAbout(data)
    }
    // Apple has no public quota API; this uses the signed-in web session rclone already stores, read in memory only.
    private func refreshICloudUsage(_ storage: Storage, binary: URL) {
        usageRefreshing.insert(storage.id)
        lastUsageAttempt[storage.id] = Date()
        forceUsage.remove(storage.id)
        let arguments = ["config", "dump"] + storage.configArguments(home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, arguments, timeoutSeconds: 30)
            var fetched: StorageUsage?
            if let result, result.code == 0,
               let all = try? JSONSerialization.jsonObject(with: result.output) as? [String: [String: String]],
               let cookies = all[storage.remote]?["cookies"] { fetched = await Self.iCloudUsage(cookies: cookies) }
            guard let self else { return }
            self.usageRefreshing.remove(storage.id)
            self.usage[storage.id] = fetched ?? .unreported(previous: self.usage[storage.id])
            self.usageStore.save(self.usage)
        }
    }
    private static func iCloudUsage(cookies: String) async -> StorageUsage? {
        func request(_ url: URL, post: Bool) -> URLRequest {
            var r = URLRequest(url: url, timeoutInterval: 20)
            r.httpShouldHandleCookies = false
            r.setValue(cookies, forHTTPHeaderField: "Cookie")
            r.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
            r.setValue("https://www.icloud.com/", forHTTPHeaderField: "Referer")
            r.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            if post { r.httpMethod = "POST"; r.httpBody = Data("null".utf8) }
            return r
        }
        guard let validate = URL(string: "https://setup.icloud.com/setup/ws/1/validate"),
              let (data, response) = try? await URLSession.shared.data(for: request(validate, post: true)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsid = (object["dsInfo"] as? [String: Any])?["dsid"] as? String,
              let base = ((object["webservices"] as? [String: Any])?["account"] as? [String: Any])?["url"] as? String,
              let url = URL(string: base + "/setup/ws/1/storageUsageInfo?dsid=" + dsid),
              url.scheme == "https", url.host?.hasSuffix(".icloud.com") == true,
              let (body, reply) = try? await URLSession.shared.data(for: request(url, post: false)),
              (reply as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return StorageUsage.fromICloud(body)
    }
    func refreshUsage(_ storage: Storage) {
        guard !Self.isPreview, !usageRefreshing.contains(storage.id), let binary = rclone else { return }
        if storage.provider == .iCloud { refreshICloudUsage(storage, binary: binary); return }
        guard storage.provider.reportsQuota else {
            usage[storage.id] = .unreported(previous: usage[storage.id])
            usageStore.save(usage)
            return
        }
        usageRefreshing.insert(storage.id)
        lastUsageAttempt[storage.id] = Date()
        forceUsage.remove(storage.id)
        let args = (storage.provider.isObjectStorage ? ["size", "--json", storage.remotePath] : ["about", "--json", storage.remotePath]) + storage.configArguments(home: home)
        Task { [weak self] in
            let result = try? await runCommand(binary, args, timeoutSeconds: 600)
            guard let self else { return }
            self.usageRefreshing.remove(storage.id)
            if let result, result.code == 0, !storage.provider.isObjectStorage,
               StorageUsage.fromAbout(result.output) == nil,
               (try? JSONSerialization.jsonObject(with: result.output)) is [String: Any] {
                if self.usage[storage.id]?.accountWide != true { self.usage[storage.id] = .unreported(previous: self.usage[storage.id]) }
                self.usageStore.save(self.usage)
                return
            }
            guard let result, result.code == 0,
                  let value = storage.provider.isObjectStorage ? StorageUsage.fromSize(result.output) : StorageUsage.fromAbout(result.output) else { return }
            self.usage[storage.id] = value
            self.usageStore.save(self.usage)
        }
    }
    private func loadPreviewData() {
        let gb: Int64 = 1_000_000_000
        func add(_ provider: Provider, _ name: String, _ root: String, used: Int64?, mounted isMounted: Bool = false, archive: Bool? = nil) {
            guard let space = try? Storage.make(provider: provider, title: name, root: root, existing: connections, readOnly: false, autoMount: false, archive: archive) else { return }
            connections.append(space)
            configured.insert(space)
            if let used { usage[space.id] = StorageUsage(usedBytes: used, totalBytes: nil, objects: nil, updated: Date()) }
            if isMounted {
                mounted.insert(space)
                statuses[space] = "Available in Finder"
                activity[space] = try? JSONDecoder().decode(CacheActivity.self, from: Data(#"{"inUse":1,"diskCache":{"bytesUsed":1800000000,"uploadsInProgress":0,"uploadsQueued":0,"erroredFiles":0,"outOfSpace":false}}"#.utf8))
            }
        }
        connections = Storage.legacy
        configured.formUnion(Storage.legacy)
        usage[Storage.googleDrive.id] = StorageUsage(usedBytes: 61 * gb, totalBytes: 100 * gb, objects: nil, updated: Date())
        mounted.insert(Storage.googleDrive)
        statuses[Storage.googleDrive] = "Available in Finder"
        add(.cloudflareR2, "Family Photos · R2", "photos-archive", used: 4 * gb + 200_000_000, mounted: true)
        add(.backblazeB2, "Backups · B2", "backups", used: 8 * gb + 600_000_000)
        add(.idriveE2, "Media Archive · e2", "media", used: 13 * gb + 400_000_000)
        add(.s3, "Cold Storage · S3", "cold-bucket", used: 120 * gb)
        add(.gcs, "Media Archive · GCS", "media-archive", used: nil)
    }
    func refreshAllUsage() {
        guard !Self.isPreview else { notice = "Preview mode: usage is sample data."; return }
        forceUsage.formUnion(connections.filter { configured.contains($0) }.map(\.id))
        lastUsageAttempt = [:]
    }
    private func fetchActivity(_ storage: Storage) async throws -> CacheActivity {
        guard let password = (try? Data(contentsOf: storage.agentURL(home: home))).flatMap(MountAgent.password(in:)) else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(storage.port)/vfs/stats")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("Basic " + Data("openshelf:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CacheActivity.self, from: data)
    }
    func setup(_ storage: Storage) {
        guard !Self.isPreview else { notice = "Preview mode: sign-in is disabled."; return }
        guard let binary = rclone,
              let script = Bundle.main.url(forResource: "connect", withExtension: "sh") else {
            notice = "Connection helper missing. Rebuild the app using the setup guide."
            return
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ["/bin/bash", script.path, binary.path, storage.remote, storage.backend, storage.ownConfig ? storage.configURL(home: home).path : ""].map(quote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")?.executeAndReturnError(&error)
        if error != nil { notice = "Terminal could not open. See the setup guide for manual connection steps." }
        else { statuses[storage] = "Finish sign-in in Terminal, then return here." }
    }
    private func updateDiskSpace() {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home.path)
        diskSpace = DiskSpace(freeBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value)
    }
    func mount(_ storage: Storage) async {
        guard !Self.isPreview else { notice = "Preview mode: nothing is mounted."; return }
        guard !busy.contains(storage), !isRunning(storage), !mounted.contains(storage), let binary = rclone else { return }
        guard configured.contains(storage) else { setup(storage); return }
        autoMountPaused.remove(storage)
        updateDiskSpace()
        guard diskSpace.canStartMount else {
            statuses[storage] = diskSpace.warning
            return
        }
        busy.insert(storage)
        statuses[storage] = "Checking your connection…"
        let check = try? await runCommand(binary, ["lsjson", storage.remotePath, "--stat", "--retries", "1", "--low-level-retries", "1", "--contimeout", "10s", "--timeout", "15s"] + storage.configArguments(home: home))
        guard check?.code == 0 else {
            busy.remove(storage)
            statuses[storage] = "Cannot reach your account. Check your internet or reconnect."
            return
        }
        do {
            let point = storage.mountPoint(home: home)
            try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
            guard try FileManager.default.contentsOfDirectory(atPath: point.path).isEmpty else {
                busy.remove(storage)
                statuses[storage] = "Finder folder must be empty before mounting."
                return
            }
            try FileManager.default.createDirectory(at: logURL(storage).deletingLastPathComponent(), withIntermediateDirectories: true)
            let password = UUID().uuidString + UUID().uuidString
            let data = try MountAgent.plist(label: MountAgent.label(for: storage), executable: binary.path, arguments: storage.arguments(home: home) + ["--log-file", logURL(storage).path], password: password)
            let agent = storage.agentURL(home: home)
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The job file holds the control-endpoint password, so it is owner-only from creation.
            try? FileManager.default.removeItem(at: agent)
            guard FileManager.default.createFile(atPath: agent.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            _ = try? await runCommand(launchctl, ["bootout", MountAgent.domain() + "/" + MountAgent.label(for: storage)])
            let launched = try await runCommand(launchctl, ["bootstrap", MountAgent.domain(), agent.path])
            guard launched.code == 0 else {
                try? FileManager.default.removeItem(at: agent)
                busy.remove(storage)
                statuses[storage] = "Could not start the drive. Open its log, then retry."
                return
            }
            agents.insert(storage)
            started[storage] = Date()
            statuses[storage] = "Opening your drive…"
        } catch {
            busy.remove(storage)
            statuses[storage] = error.localizedDescription
        }
    }
    func unmount(_ storage: Storage) async {
        guard !Self.isPreview else { notice = "Preview mode: nothing is mounted."; return }
        guard !busy.contains(storage), mounted.contains(storage) else { return }
        guard agents.contains(storage) else {
            statuses[storage] = "This drive was started by an older OpenShelf version. Quit that version to disconnect it."
            return
        }
        autoMountPaused.insert(storage)
        busy.insert(storage)
        defer { busy.remove(storage) }
        // Refuse to stop a drive unless live VFS stats confirm it is idle.
        guard let stats = try? await fetchActivity(storage), stats.canUnmount else {
            statuses[storage] = "Close open files and wait for uploads before disconnecting. Transfer status must be available."
            return
        }
        statuses[storage] = "Disconnecting…"
        let result = try? await runCommand(URL(fileURLWithPath: "/usr/sbin/diskutil"), ["unmount", storage.mountPoint(home: home).path])
        if result?.code == 0 {
            await stopAgent(storage)
            agents.remove(storage)
            mounted.remove(storage)
            activity[storage] = nil
            statuses[storage] = "Drive disconnected. Your cloud files are still safe."
        } else {
            statuses[storage] = "Drive is busy. Close files and Finder windows, then retry."
        }
    }
}

struct RemoteSummary: Decodable {
    let name: String
    let type: String
}
