import Foundation

let home = URL(fileURLWithPath: "/tmp/openshelf-check")
precondition(Storage.googleDrive.remote != Storage.iCloud.remote)
precondition(Storage.googleDrive.mountPoint(home: home) != Storage.iCloud.mountPoint(home: home))
precondition(Storage.googleDrive.cache(home: home) != Storage.iCloud.cache(home: home))
precondition(Storage.googleDrive.port != Storage.iCloud.port)
for storage in Storage.legacy {
    let args = storage.arguments(home: home)
    precondition(Array(args.prefix(3)) == ["nfsmount", "\(storage.remote):", storage.mountPoint(home: home).path])
    precondition(args[args.firstIndex(of: "--cache-dir")! + 1] == storage.cache(home: home).path)
    precondition(args.contains("nolocks") && args.contains("noappledouble"))
    precondition(args[args.firstIndex(of: "--addr")! + 1] == "127.0.0.1:0")
    precondition(!args.contains("--allow-non-empty") && !args.contains("--daemon"))
}
func stats(uploads: Int = 0, queued: Int = 0, errors: Int = 0, full: Bool = false) throws -> CacheActivity {
    let data = """
    {"inUse":1,"diskCache":{"bytesUsed":100,"uploadsInProgress":\(uploads),"uploadsQueued":\(queued),"erroredFiles":\(errors),"outOfSpace":\(full)}}
    """
    return try JSONDecoder().decode(CacheActivity.self, from: Data(data.utf8))
}
let idle = try stats()
let uploading = try stats(uploads: 1)
let queued = try stats(queued: 1)
let failed = try stats(errors: 1)
let full = try stats(full: true)
precondition(idle.canUnmount)
precondition(!uploading.canUnmount && !queued.canUnmount && !failed.canUnmount && !full.canUnmount)
print("PASS: provider isolation, loopback binding, macOS mount options, and upload disconnect guards")

precondition(DiskSpace(freeBytes: nil).canStartMount == false)
precondition(DiskSpace(freeBytes: DiskSpace.reserveBytes - 1).canStartMount == false)
precondition(DiskSpace(freeBytes: DiskSpace.reserveBytes).canStartMount)
precondition(DiskSpace(freeBytes: DiskSpace.reserveBytes + 1).warning == nil)
precondition(DiskSpace(freeBytes: 0).warning != nil)
for storage in Storage.legacy {
    let args = storage.arguments(home: home)
    precondition(args[args.firstIndex(of: "--vfs-cache-min-free-space")! + 1] == "10G")
}
print("PASS: low disk, unknown capacity, reserve boundary, and cache reserve settings")

let now = Date()
func attempt(configured: Bool = true, mounted: Bool = false, running: Bool = false,
             busy: Bool = false, paused: Bool = false, lastAttempt: Date? = nil) -> Bool {
    AutoMountPolicy.shouldAttempt(configured: configured, mounted: mounted, running: running,
                                 busy: busy, paused: paused, lastAttempt: lastAttempt, now: now)
}
precondition(attempt())
precondition(!attempt(configured: false) && !attempt(mounted: true) && !attempt(running: true))
precondition(!attempt(busy: true) && !attempt(paused: true))
precondition(!attempt(lastAttempt: now.addingTimeInterval(-59)))
precondition(attempt(lastAttempt: now.addingTimeInterval(-60)))
print("PASS: automatic mount, duplicate prevention, manual pause, and network retry interval")

let workDrive = try Storage.make(provider: .googleDrive, title: "Work Drive", root: "Projects", existing: Storage.legacy, readOnly: true, autoMount: false)
let secondDrive = try Storage.make(provider: .googleDrive, title: "Work Drive", root: "", existing: Storage.legacy + [workDrive], readOnly: false, autoMount: true)
precondition(workDrive.id != secondDrive.id && workDrive.remote != secondDrive.remote)
precondition(workDrive.directory != secondDrive.directory && workDrive.port != secondDrive.port)
precondition(workDrive.cache(home: home) != secondDrive.cache(home: home))
precondition(workDrive.configURL(home: home) != secondDrive.configURL(home: home))
precondition(workDrive.remotePath.hasSuffix(":Projects"))
precondition(workDrive.arguments(home: home).contains("--read-only"))
precondition(!secondDrive.arguments(home: home).contains("--read-only"))
precondition(!Storage.googleDrive.ownConfig && Storage.googleDrive.configArguments(home: home).isEmpty)
for provider in Provider.selectable {
 let account = try Storage.make(provider: provider, title: provider.title, root: provider.isObjectStorage ? "bucket/prefix" : "", existing: Storage.legacy, readOnly: false, autoMount: true)
 precondition(account.backend == provider.backend)
 precondition(account.ownConfig && !account.configArguments(home: home).isEmpty)
}
let testHome = FileManager.default.temporaryDirectory.appendingPathComponent("openshelf-manifest-" + UUID().uuidString)
let store = ConnectionStore(home: testHome)
let migrated = try store.load()
precondition(migrated.map(\.id) == Storage.legacy.map(\.id))
precondition(migrated[0].mountPoint(home: testHome).lastPathComponent == "Google Drive")
precondition(migrated[1].cacheKey == "iCloud")
try store.save(migrated + [workDrive, secondDrive])
let restored = try store.load()
precondition(restored.count == 4 && restored[2].readOnly && !restored[2].autoMount)
precondition(restored[2].root == "Projects" && restored[3].port == secondDrive.port)
let manifest = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
precondition(!manifest.contains("client_secret") && !manifest.contains("access_token"))
try store.save([workDrive, workDrive])
do { _ = try store.load(); fatalError("Duplicate identities must be refused") } catch StorageError.invalidManifest {}
try Data("corrupt".utf8).write(to: store.url)
do { _ = try store.load(); fatalError("Corrupt manifests must not silently reset") } catch {}
for invalid in ["", "../escape", "a/b", "a\nb"] {
 do { _ = try Storage.make(provider: .googleDrive, title: invalid, root: "", existing: [], readOnly: false, autoMount: true); fatalError("Invalid name accepted") } catch StorageError.invalidName {}
}
let tokenOutput = Data("Paste the following into your remote machine --->\n{\"access_token\":\"test-only\",\"refresh_token\":\"test-only\"}\n<---End paste\n".utf8)
let parsedToken = try GoogleAuthorization.token(from: tokenOutput)
precondition(parsedToken.contains("test-only"))
do { _ = try GoogleAuthorization.token(from: Data("cancelled".utf8)); fatalError("Invalid authorization accepted") } catch {}
try FileManager.default.removeItem(at: testHome)
print("PASS: multi-account isolation, all provider descriptors, legacy migration, persistence, read-only mounts, corrupt manifest refusal, and OAuth response parsing")

// Archive providers, quota tracking, and manifest migration.
for provider in [Provider.cloudflareR2, .backblazeB2, .idriveE2] {
 precondition(provider.isObjectStorage && provider.prefersArchive && provider.freeTierBytes == 10_000_000_000)
 let space = try Storage.make(provider: provider, title: provider.title, root: "bucket", existing: [], readOnly: false, autoMount: false)
 precondition(space.isArchive)
 let args = space.arguments(home: home)
 precondition(args[args.firstIndex(of: "--vfs-cache-max-age")! + 1] == "72h" && args.contains("--dir-cache-time"))
}
precondition(Provider.cloudflareR2.s3Flavor == "Cloudflare" && Provider.idriveE2.s3Flavor == "IDrive" && Provider.backblazeB2.backend == "b2" && Provider.backblazeB2.s3Flavor == nil)
precondition(!Storage.googleDrive.isArchive && Storage.googleDrive.provider.freeTierBytes == nil)
let live = try Storage.make(provider: .s3, title: "Live", root: "b", existing: [], readOnly: false, autoMount: true, archive: false)
precondition(!live.isArchive && live.arguments(home: home).contains("1h") && !live.arguments(home: home).contains("--dir-cache-time"))
let legacyJSON = Data("""
[{"id":"abc","provider":"gcs","title":"Old","remote":"openshelf-abc","backend":"google cloud storage","root":"b","directory":"Old · abc","cacheKey":"abc","port":55740,"ownConfig":true,"autoMount":true,"readOnly":false}]
""".utf8)
let oldItems = try JSONDecoder().decode([Storage].self, from: legacyJSON)
precondition(oldItems[0].isArchive)
let roundTrip = try JSONDecoder().decode([Storage].self, from: JSONEncoder().encode([live]))
precondition(!roundTrip[0].isArchive)

let r2 = try Storage.make(provider: .cloudflareR2, title: "R2", root: "b", existing: [], readOnly: false, autoMount: false)
precondition(r2.quota(for: nil) == nil)
func level(_ used: Int64) -> QuotaLevel { r2.quota(for: StorageUsage(usedBytes: used, totalBytes: nil, objects: nil, updated: Date()))!.level }
precondition(level(0) == .ok && level(7_999_999_999) == .ok && level(8_000_000_000) == .warning && level(10_000_000_000) == .exceeded)
let over = r2.quota(for: StorageUsage(usedBytes: 12_500_000_000, totalBytes: nil, objects: nil, updated: Date()))!
precondition(over.overage == 2_500_000_000 && over.remaining == 0 && over.fraction == 1)
precondition(QuotaStatus(used: 5, limit: nil).level == .unlimited)
let s3 = try Storage.make(provider: .s3, title: "S3", root: "b", existing: [], readOnly: false, autoMount: false)
precondition(s3.quota(for: StorageUsage(usedBytes: 1 << 40, totalBytes: nil, objects: nil, updated: Date()))!.level == .unlimited)
let drive = Storage.googleDrive.quota(for: StorageUsage(usedBytes: 15, totalBytes: 100, objects: nil, updated: Date()))!
precondition(drive.remaining == 85 && drive.level == .ok)
precondition(StorageUsage.fromSize(Data(#"{"count":5,"bytes":98568,"sizeless":0}"#.utf8))?.usedBytes == 98568)
precondition(StorageUsage.fromAbout(Data(#"{"total":100,"used":40,"free":60}"#.utf8))?.totalBytes == 100)
precondition(StorageUsage.fromAbout(Data(#"{"total":100,"free":60}"#.utf8))?.usedBytes == 40)
precondition(StorageUsage.fromSize(Data("garbage".utf8)) == nil)
let usageHome = FileManager.default.temporaryDirectory.appendingPathComponent("openshelf-usage-" + UUID().uuidString)
let usageStore = UsageStore(home: usageHome)
precondition(usageStore.load().isEmpty)
usageStore.save(["x": StorageUsage(usedBytes: 7, totalBytes: nil, objects: 1, updated: Date())])
precondition(usageStore.load()["x"]?.usedBytes == 7)
try FileManager.default.removeItem(at: usageHome)
print("PASS: R2/B2/e2 providers, archive mode, legacy manifest migration, free-tier quota levels, and usage parsing/persistence")

// Detached mount agents.
let agentData = try MountAgent.plist(label: "org.openshelf.mount.x", executable: "/bin/rclone", arguments: ["nfsmount", "a:", "/m"], password: "pw-test")
precondition(MountAgent.password(in: agentData) == "pw-test")
let agentObject = try PropertyListSerialization.propertyList(from: agentData, options: [], format: nil) as! [String: Any]
precondition(agentObject["KeepAlive"] as? Bool == false && (agentObject["ProgramArguments"] as! [String]).first == "/bin/rclone")
precondition(!String(decoding: arguments(for: r2, home: home), as: UTF8.self).contains("pw-test"))
let listing = "PID\tStatus\tLabel\n123\t0\torg.openshelf.mount.a\n-\t1\torg.openshelf.mount.b\n99\t0\tcom.apple.other\n"
precondition(MountAgent.parseList(listing) == ["org.openshelf.mount.a": true, "org.openshelf.mount.b": false])
precondition(MountAgent.label(for: r2).hasPrefix("org.openshelf.mount.") && r2.agentURL(home: home).path.hasSuffix("agents/\(r2.id).plist"))
precondition(!Provider.cloudflareR2.chargesEgress && !Provider.backblazeB2.chargesEgress && Provider.s3.chargesEgress && Provider.gcs.chargesEgress)
print("PASS: detached mount agent job file, secret handling, launchctl parsing, and egress classification")
func arguments(for storage: Storage, home: URL) -> Data { Data(storage.arguments(home: home).joined(separator: " ").utf8) }

// Guided setup and forgiving input.
for provider in Provider.selectable { precondition(!(provider.guide?.steps.isEmpty ?? true)) }
precondition(Provider.cloudflareR2.guide?.consoleURL?.scheme == "https")
precondition(EndpointInput.r2AccountID("abc123def") == "abc123def")
precondition(EndpointInput.r2AccountID("https://abc123def.r2.cloudflarestorage.com/bucket") == "abc123def")
precondition(EndpointInput.r2AccountID("bad id!") == nil)
precondition(EndpointInput.https("s3.example.com") == "https://s3.example.com" && EndpointInput.https(" https://x.y ") == "https://x.y")
print("PASS: guided setup content and endpoint normalisation")

let junk = try Storage.make(provider: .cloudflareR2, title: "Junk", root: "bucket", existing: [], readOnly: false, autoMount: false).junkCleanupArguments(home: home)
precondition(junk.first == "delete" && junk.contains("._*") && junk.contains(".DS_Store") && !junk.contains("--rmdirs"))

precondition(!Provider.iCloud.reportsQuota && Provider.googleDrive.reportsQuota)
let unreported = StorageUsage.unreported()
precondition(!unreported.isReported && Storage.googleDrive.quota(for: unreported) == nil)
precondition(Storage.googleDrive.quota(for: StorageUsage(usedBytes: 1, totalBytes: 10, objects: nil, updated: Date(), unsupported: nil))?.remaining == 9)
let legacyHome = FileManager.default.temporaryDirectory.appendingPathComponent("os-mig-\(UUID().uuidString)")
for rel in LegacyMigration.locations {
    let base = rel.isEmpty ? legacyHome : legacyHome.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("CloudShelf/keep"), withIntermediateDirectories: true)
}
precondition(LegacyMigration.run(home: legacyHome, mountPaths: [legacyHome.path + "/CloudShelf/Google Drive"]) == 3, "mounted home folder is skipped, others move")
precondition(FileManager.default.fileExists(atPath: legacyHome.appendingPathComponent("CloudShelf/keep").path))
precondition(FileManager.default.fileExists(atPath: legacyHome.appendingPathComponent("Library/Caches/OpenShelf/keep").path))
precondition(LegacyMigration.run(home: legacyHome, mountPaths: []) == 1 && FileManager.default.fileExists(atPath: legacyHome.appendingPathComponent("OpenShelf/keep").path))
try? FileManager.default.removeItem(at: legacyHome)
print("PASS: unreported quota handling and legacy folder migration")

do {
    let r2 = try Storage.make(provider: .cloudflareR2, title: "Photos", root: "bucket", existing: [], readOnly: false, autoMount: true)
    let edited = try r2.updating(title: " Family ", root: "/bucket/2024/", readOnly: true, autoMount: false, mode: .live, existing: [r2])
    precondition(edited.id == r2.id && edited.port == r2.port && edited.remote == r2.remote && edited.cacheKey == r2.cacheKey)
    precondition(edited.title == "Family" && edited.root == "bucket/2024" && edited.readOnly && !edited.autoMount && !edited.isArchive)
    precondition(edited.directory == "Family (Cloudflare R2) · " + String(r2.id.prefix(8)))
    for bad in [("", "bucket"), ("a/b", "bucket"), ("ok", ""), ("ok", "a/../b")] {
        precondition((try? r2.updating(title: bad.0, root: bad.1, readOnly: false, autoMount: true, mode: .archive, existing: [r2])) == nil)
    }
    let drive = try Storage.googleDrive.updating(title: "Work", root: "", readOnly: false, autoMount: true, mode: .archive, existing: [])
    precondition(drive.directory == "Google Drive" && drive.title == "Work" && !drive.isArchive && drive.remote == "cloudshelf-google")
    print("PASS: editing connection details keeps identity, validates input, and keeps built-in folders")
}

precondition(TagInput.parse(" Work, family ;work,, backup ") == ["Work", "family", "backup"])
precondition(TagInput.parse((1...20).map(String.init).joined(separator: ",")).count == 8)
let tagged = try Storage.make(provider: .backblazeB2, title: "Tagged", root: "b", existing: [], readOnly: false, autoMount: true)
let labelled = try tagged.updating(title: tagged.title, root: tagged.root, readOnly: false, autoMount: true, mode: .archive, tags: ["x"], note: " hello ", existing: [tagged])
precondition(labelled.tags == ["x"] && labelled.note == "hello" && labelled.directory == tagged.directory)
let reloaded = try JSONDecoder().decode(Storage.self, from: JSONEncoder().encode(labelled))
precondition(reloaded.tags == ["x"] && reloaded.note == "hello")
let google = AccountIdentity.googleAbout(Data(#"{"user":{"emailAddress":"a@example.com","displayName":"A"},"storageQuota":{"limit":"2000","usage":"500"}}"#.utf8))
precondition(google?.identity.email == "a@example.com" && google?.usage?.totalBytes == 2000 && google?.usage?.accountWide == true)
precondition(Storage.googleDrive.quota(for: google?.usage)?.remaining == 1500)
precondition(AccountIdentity.googleAbout(Data("{}".utf8)) == nil)
precondition(AccountIdentity.from(provider: .iCloud, config: ["apple_id": "me@icloud.com", "password": "x"]).email == "me@icloud.com")
precondition(AccountIdentity.from(provider: .cloudflareR2, config: ["endpoint": "https://abc.r2.cloudflarestorage.com"]).detail == "abc.r2.cloudflarestorage.com")
var measuredUsage = StorageUsage.unreported(); measuredUsage.usedBytes = 42; measuredUsage.measured = true
precondition(StorageUsage.unreported(previous: measuredUsage).usedBytes == 42 && StorageUsage.unreported().usedBytes == 0)
print("PASS: tags/notes, account identity parsing, Google account quota, measured sizes")

let apple = StorageUsage.fromICloud(Data(#"{"storageUsageInfo":{"usedStorageInBytes":196901689385,"totalStorageInBytes":2199023255552}}"#.utf8))
precondition(apple?.usedBytes == 196901689385 && apple?.totalBytes == 2199023255552 && apple?.accountWide == true)
precondition(Storage.iCloud.quota(for: apple)?.level == .ok && StorageUsage.fromICloud(Data("{}".utf8)) == nil)
precondition(Provider.iCloud.accountName == "iCloud")
let renamed = try tagged.updating(title: "New name", root: tagged.root, readOnly: false, autoMount: true, mode: .archive, keepFolder: true, existing: [tagged])
precondition(renamed.title == "New name" && renamed.directory == tagged.directory && renamed.mountPoint(home: home) == tagged.mountPoint(home: home))
print("PASS: iCloud account usage parsing and renaming a mounted space")

let r2Price = Provider.cloudflareR2.pricing!
precondition(r2Price.monthlyStorageCost(usedBytes: 5_000_000_000) == 0)
precondition(abs(r2Price.monthlyStorageCost(usedBytes: 110_000_000_000) - 1.5) < 0.0001)
precondition(Provider.gcs.pricing!.freeBytes == nil && abs(Provider.gcs.pricing!.monthlyStorageCost(usedBytes: 17_700_000_000) - 0.354) < 0.0001)
precondition(Provider.googleDrive.pricing == nil && Provider.iCloud.pricing == nil)
precondition(Provider.allCases.filter { $0.isObjectStorage && $0 != .other && $0 != .s3Compatible }.allSatisfy { $0.pricing != nil })
precondition(PricingInfo.dollars(0.004) == "<$0.01" && PricingInfo.dollars(1.5) == "$1.50")
print("PASS: pay-as-you-go pricing estimates")

precondition(abs(RestoreCost.estimate(bytes: 50_000_000_000, provider: .gcs)! - 6.0) < 0.0001)
precondition(RestoreCost.estimate(bytes: 50_000_000_000, provider: .cloudflareR2) == nil)
precondition(Budget.level(cost: 0.5, budget: nil) == .none && Budget.level(cost: 0.5, budget: 1) == .ok)
precondition(Budget.level(cost: 0.85, budget: 1) == .nearing && Budget.level(cost: 1.2, budget: 1) == .exceeded)
let day0 = Date(timeIntervalSince1970: 1_800_000_000)
var samples = UsageHistory.record(1_000_000_000, at: day0, into: [])
samples = UsageHistory.record(2_000_000_000, at: day0.addingTimeInterval(1_000), into: samples)
precondition(samples.count == 1 && samples[0].bytes == 2_000_000_000)
precondition(UsageHistory.daysUntil(limit: 10_000_000_000, samples: samples) == nil)
samples = UsageHistory.record(4_000_000_000, at: day0.addingTimeInterval(2 * 86_400), into: samples)
precondition(abs(UsageHistory.growthPerDay(samples)! - 1_000_000_000) < 20_000_000)
precondition(UsageHistory.daysUntil(limit: 10_000_000_000, samples: samples)! >= 5)
precondition(UsageHistory.daysUntil(limit: 3_000_000_000, samples: samples) == 0)
let total = CostSummary.monthlyTotal([(.cloudflareR2, 5_000_000_000), (.gcs, 10_000_000_000), (.googleDrive, 99)])
precondition(abs(total - 0.2) < 0.0001)
let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent("os-budget-\(UUID().uuidString)")
BudgetStore(home: tmpHome).save(["a": 2.5])
precondition(BudgetStore(home: tmpHome).load()["a"] == 2.5)
print("PASS: restore cost, budgets, usage history and forecast")

precondition(Provider.wasabi.s3Flavor == "Wasabi" && Provider.digitalOceanSpaces.s3Flavor == "DigitalOcean")
precondition(Provider.wasabi.backend == "s3" && Provider.wasabi.isObjectStorage && Provider.digitalOceanSpaces.prefersArchive)
precondition(Provider.wasabi.pricing != nil && Provider.digitalOceanSpaces.guide != nil && Provider.wasabi.freeTierBytes == nil)
precondition(Provider.selectable.contains(.wasabi) && !Provider.wasabi.chargesEgress)
print("PASS: Wasabi and DigitalOcean Spaces providers")

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
let sas = "https://acct.blob.core.windows.net/box?sv=2022&se=2027-01-20T08:00:00Z&sp=rl&sig=abc"
let expiry = CredentialHealth.sasExpiry(sas)
precondition(expiry == Date(timeIntervalSince1970: 1_800_432_000))
precondition(CredentialHealth.sasExpiry("https://x/y?sv=1") == nil)
precondition(CredentialHealth.warning(expiry: fixedNow.addingTimeInterval(3 * 86_400), now: fixedNow)?.contains("expires in 3 days") == true)
precondition(CredentialHealth.warning(expiry: fixedNow.addingTimeInterval(60 * 86_400), now: fixedNow) == nil)
precondition(CredentialHealth.warning(expiry: fixedNow.addingTimeInterval(-10), now: fixedNow)?.contains("expired") == true)
precondition(CredentialHealth.configValue("sas_url", in: "[r]\ntype = azureblob\nsas_url = https://a?se=1\n") == "https://a?se=1")
let archiveSpace = try Storage.make(provider: .cloudflareR2, title: "Arch", root: "bucket", existing: [], readOnly: false, autoMount: false, archive: true)
let copyArgs = archiveSpace.archiveCopyArguments(source: URL(fileURLWithPath: "/tmp/photos"), subfolder: "/2026/", home: home)
precondition(copyArgs[0] == "copy" && copyArgs[1] == "/tmp/photos" && copyArgs[2].hasSuffix("bucket/2026") && copyArgs.contains("._*") && !copyArgs.contains("sync"))
precondition(archiveSpace.verifyArguments(source: URL(fileURLWithPath: "/tmp/photos"), subfolder: "", home: home)[0] == "check")
print("PASS: archive copy/verify arguments and credential expiry warnings")

var events: [ActivityEvent] = []
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
events = ActivityLog.append("Could not clean junk files.", at: t0, to: events)
events = ActivityLog.append("Could not clean junk files.", at: t0.addingTimeInterval(2), to: events)
precondition(events.count == 1 && events[0].level == .error)
events = ActivityLog.append("Verified: every file is safe.", at: t0.addingTimeInterval(60), to: events)
precondition(events.count == 2 && events[0].level == .info && events[0].message.hasPrefix("Verified"))
for i in 0..<300 { events = ActivityLog.append("m\(i)", at: t0.addingTimeInterval(Double(100 + i * 10)), to: events) }
precondition(events.count == ActivityLog.limit && events[0].message == "m299")
precondition(ActivityLog.level(for: "The access token for this space expires in 3 days.") == .warning)
let eventHome = FileManager.default.temporaryDirectory.appendingPathComponent("os-events-\(UUID().uuidString)")
EventStore(home: eventHome).save(events)
precondition(EventStore(home: eventHome).load().count == ActivityLog.limit)
print("PASS: activity log")

let r2Json = #"{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[{"sum":{"requests":1500000},"dimensions":{"actionType":"PutObject"}},{"sum":{"requests":300},"dimensions":{"actionType":"GetObject"}},{"sum":{"requests":50},"dimensions":{"actionType":"DeleteObject"}}],"r2StorageAdaptiveGroups":[{"max":{"objectCount":42,"payloadSize":9000000000,"metadataSize":1000}}]}]}}}"#
let insight = R2Analytics.parse(Data(r2Json.utf8))!
precondition(insight.classA == 1_500_000 && insight.classB == 300 && insight.objects == 42 && insight.storageBytes == 9_000_001_000)
precondition(abs(insight.requestCost - 4.5) < 1e-9)
precondition(R2Analytics.parse(Data(#"{"errors":[{"message":"x"}],"data":null}"#.utf8)) == nil)
precondition(R2Analytics.bucket(of: "media/2026") == "media" && R2Analytics.bucket(of: "") == nil)
precondition(R2Analytics.accountID(fromHost: "abc123.r2.cloudflarestorage.com") == "abc123" && R2Analytics.accountID(fromHost: "s3.example.com") == nil)
let req = R2Analytics.request(token: "t", account: "acc", bucket: "b", now: Date(timeIntervalSince1970: 1_800_000_000))
precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer t" && req.httpMethod == "POST" && String(data: req.httpBody!, encoding: .utf8)!.contains("r2OperationsAdaptiveGroups"))
let pooled = FreeTierPool.costs([("a", .cloudflareR2, "acct", 8_000_000_000), ("b", .cloudflareR2, "acct", 12_000_000_000), ("c", .cloudflareR2, nil, 5_000_000_000), ("d", .gcs, nil, 10_000_000_000)])
precondition(abs(pooled["a"]! - 0.06) < 1e-9 && abs(pooled["b"]! - 0.09) < 1e-9 && pooled["c"] == 0 && abs(pooled["d"]! - 0.2) < 1e-9)
var alertState: [String: Int] = [:]
var step = AlertTracker.update(alertState, key: "x", level: 1); alertState = step.state
precondition(step.notify)
step = AlertTracker.update(alertState, key: "x", level: 1); precondition(!step.notify)
step = AlertTracker.update(alertState, key: "x", level: 2); alertState = step.state; precondition(step.notify)
step = AlertTracker.update(alertState, key: "x", level: 0); alertState = step.state; precondition(alertState.isEmpty)
step = AlertTracker.update(alertState, key: "x", level: 1); precondition(step.notify)
print("PASS: R2 analytics, pooled free tier, alert de-duplication")

do {
    let now = Date()
    let gb: Int64 = 1_000_000_000
    let totals = ShelfTotals.make([
        ("a", .googleDrive, nil, StorageUsage(usedBytes: 60 * gb, totalBytes: 100 * gb, objects: nil, updated: now)),
        ("b", .googleDrive, nil, StorageUsage(usedBytes: 60 * gb, totalBytes: 100 * gb, objects: nil, updated: now)),
        ("c", .cloudflareR2, "acct", StorageUsage(usedBytes: 3 * gb, totalBytes: nil, objects: nil, updated: now)),
        ("d", .cloudflareR2, "acct", StorageUsage(usedBytes: 4 * gb, totalBytes: nil, objects: nil, updated: now)),
        ("e", .s3, nil, StorageUsage(usedBytes: 5 * gb, totalBytes: nil, objects: nil, updated: now)),
    ])
    precondition(totals.storedBytes == 72 * gb && totals.quotaLeft == 40 * gb && totals.quotaAccounts == 1 && totals.freeTierLeft == 3 * gb)
    print("PASS: shelf totals dedupe quotas and pool free tier")
}

do {
    let plain = try Storage.make(provider: .cloudflareR2, title: "Vault", root: "bucket/sub", existing: [], readOnly: false, autoMount: false)
    let secure = try Storage.make(provider: .cloudflareR2, title: "Vault", root: "bucket/sub", existing: [], readOnly: false, autoMount: false, encrypted: true)
    let imported = try Storage.make(provider: .cloudflareR2, title: "Vault", root: "b", existing: [], readOnly: false, autoMount: false, remote: "mine", encrypted: true)
    precondition(plain.remotePath == plain.remote + ":bucket/sub" && !plain.encrypted)
    precondition(secure.encrypted && secure.remotePath == secure.remote + "-crypt:" && secure.underlyingPath == secure.remote + ":bucket/sub")
    precondition(!imported.encrypted, "saved remotes are never wrapped")
    let decoded = try JSONDecoder().decode(Storage.self, from: JSONEncoder().encode(secure))
    precondition(decoded.encrypted && decoded.remotePath == secure.remotePath)
    let renamed = try secure.updating(title: "Other", root: "elsewhere", readOnly: false, autoMount: false, mode: .archive, existing: [secure])
    precondition(renamed.root == "bucket/sub" && renamed.remotePath == secure.remotePath)
    let section = CryptConfig.section(name: "x-crypt", target: "x:b", password: "P", salt: "S")
    precondition(section.contains("type = crypt") && section.contains("remote = x:b") && section.contains("password2 = S"))
    let secret = CryptConfig.randomSecret()
    precondition(secret.count >= 40 && secret != CryptConfig.randomSecret() && !secret.contains("="))
    print("PASS: optional encryption overlay, recovery section, legacy decoding")
}

do {
    struct Entry: Decodable { let id: String; let title: String; let backend: String; let s3Flavor: String?; let freeTierBytes: Int64?; let chargesEgress: Bool; let pricePerGb: Double? }
    struct Catalogue: Decodable { let providers: [Entry] }
    let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: URL(fileURLWithPath: "providers.json")))
    let byID: [String: Provider] = ["r2": .cloudflareR2, "b2": .backblazeB2, "e2": .idriveE2, "s3": .s3, "gcs": .gcs, "azure": .azureBlob, "wasabi": .wasabi, "do": .digitalOceanSpaces, "s3c": .s3Compatible]
    precondition(catalogue.providers.count == byID.count)
    for entry in catalogue.providers {
        guard let provider = byID[entry.id] else { fatalError("unmapped catalogue id \(entry.id)") }
        precondition(provider.title == entry.title && provider.backend == entry.backend && provider.s3Flavor == entry.s3Flavor, "identity drift for \(entry.id)")
        precondition(provider.freeTierBytes == entry.freeTierBytes && provider.chargesEgress == entry.chargesEgress, "free tier/egress drift for \(entry.id)")
        precondition(provider.pricing?.storagePerGB == entry.pricePerGb, "price drift for \(entry.id)")
    }
    print("PASS: Swift providers match providers.json")
}

do {
    let full = UsageHint.text(provider: .googleDrive, level: .exceeded)!
    precondition(full.contains("full") && full.contains("no pay-as-you-go"))
    precondition(UsageHint.text(provider: .iCloud, level: .ok)!.contains("fixed storage plan"))
    let over = UsageHint.text(provider: .cloudflareR2, level: .exceeded, overageBytes: 5_000_000_000)!
    precondition(over.contains("pay-as-you-go") && over.contains("5") && over.contains("$0.015"))
    precondition(UsageHint.text(provider: .backblazeB2, level: .ok)!.contains("free each month"))
    precondition(UsageHint.text(provider: .gcs, level: .unlimited)!.contains("Downloading data back"))
    precondition(UsageHint.text(provider: .other, level: .ok) == nil)
    print("PASS: pay-as-you-go and fixed-plan tooltip wording")
}

do {
    let home = URL(fileURLWithPath: "/h", isDirectory: true)
    let shared = Storage.accountTokenURL(home: home, account: "abc123")
    precondition(shared.lastPathComponent == "cf-abc123.cftoken" && shared.path.hasSuffix("accounts/cf-abc123.cftoken"))
    print("PASS: Cloudflare token is stored per account")
}
