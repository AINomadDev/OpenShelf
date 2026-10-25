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
    precondition(edited.directory == "Family · " + String(r2.id.prefix(8)))
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
