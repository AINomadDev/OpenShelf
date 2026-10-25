import SwiftUI
import AppKit

@MainActor
final class ConnectionDraft: ObservableObject {
    @Published var step = 0
    @Published var provider: Provider = .googleDrive
    @Published var name = ""
    @Published var root = ""
    @Published var autoMount = true
    @Published var readOnly = false
    @Published var archive = true
    @Published var reuseGoogleClient = true
    @Published var fields: [String: String] = [:]
    @Published var importing = false
    @Published var remotes: [RemoteSummary] = []
    @Published var selectedRemote = ""
    @Published var working = false
    @Published var message: String?
    @Published var replacingCredentials = false
    @Published var tagsText = ""
    @Published var note = ""
    private var authProcess: Process?
    private var cancelled = false
    private let home = FileManager.default.homeDirectoryForCurrentUser
    func value(_ key: String) -> Binding<String> {
        Binding(get: { self.fields[key] ?? "" }, set: { self.fields[key] = $0 })
    }
    func cancel() { cancelled = true; authProcess?.terminate() }
    func loadRemotes(_ manager: DriveManager) async {
        guard let binary = manager.rclone,
              let result = try? await runCommand(binary, ["listremotes", "--json"]), result.code == 0 else { return }
        remotes = (try? JSONDecoder().decode([RemoteSummary].self, from: result.output)) ?? []
        selectedRemote = remotes.first?.name ?? ""
    }
    func chooseCredentialFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { fields["credential_file"] = panel.url?.path }
    }
    private func writeConfig(_ values: [String: String], storage: Storage) throws {
        let url = storage.configURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard values.values.allSatisfy({ !$0.contains(where: { $0.isNewline }) }) else { throw SetupError.lineBreak }
        let text = "[\(storage.remote)]\n" + values.keys.sorted().map { "\($0) = \(values[$0]!)\n" }.joined()
        // Create with owner-only permissions from the start so secrets are never briefly world-readable.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    }
    func connect(_ manager: DriveManager) async {
        guard !working, let binary = manager.rclone else { return }
        working = true
        cancelled = false
        message = nil
        defer {
            if manager.authenticationProcess === authProcess { manager.authenticationProcess = nil }
            working = false
            authProcess = nil
        }
        var pending: Storage?
        do {
            if importing {
                guard let remote = remotes.first(where: { $0.name == selectedRemote }) else { throw SetupError.missing("existing connection") }
                let provider = Provider.selectable.first(where: { $0.backend == remote.type }) ?? .other
                let storage = try Storage.make(provider: provider, title: name, root: root, existing: manager.connections, readOnly: readOnly, autoMount: autoMount, remote: remote.name, backend: remote.type, archive: archive && provider.prefersArchive)
                try await validate(binary, storage)
                guard !cancelled else { throw SetupError.authorization }
                try manager.add(storage)
                manager.showingAddStorage = false
                return
            }
            if provider.isObjectStorage && root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SetupError.missing("bucket or container") }
            let storage = try Storage.make(provider: provider, title: name, root: root, existing: manager.connections, readOnly: readOnly, autoMount: autoMount, archive: archive && provider.prefersArchive)
            pending = storage
            var values = ["type": provider.backend]
            func required(_ key: String, _ label: String) throws -> String {
                guard let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw SetupError.missing(label) }
                return value
            }
            switch provider {
            case .googleDrive:
                var clientID = fields["client_id"] ?? ""
                var clientSecret = fields["client_secret"] ?? ""
                if reuseGoogleClient {
                    // Read only in-process. This output is never logged or shown in the UI.
                    let result = try await runCommand(binary, ["config", "dump"])
                    guard result.code == 0,
                          let all = try JSONSerialization.jsonObject(with: result.output) as? [String: [String: String]],
                          let existing = all.values.first(where: { $0["type"] == "drive" && !($0["client_id"] ?? "").isEmpty && !($0["client_secret"] ?? "").isEmpty }) else { throw SetupError.noGoogleClient }
                    clientID = existing["client_id"] ?? ""
                    clientSecret = existing["client_secret"] ?? ""
                }
                guard !clientID.isEmpty && !clientSecret.isEmpty else { throw SetupError.missing("Google app client ID and secret") }
                var environment = ProcessInfo.processInfo.environment
                environment["RCLONE_DRIVE_CLIENT_ID"] = clientID
                environment["RCLONE_DRIVE_CLIENT_SECRET"] = clientSecret
                environment["RCLONE_DRIVE_SCOPE"] = readOnly ? "drive.readonly" : "drive"
                message = "Complete Google sign-in in your browser. Choose the account for this space."
                guard !cancelled else { throw SetupError.authorization }
                let process = Process()
                authProcess = process
                manager.authenticationProcess = process
                let result = try await runCommand(binary, ["authorize", "drive"], environment: environment, timeoutSeconds: 300, suppliedProcess: process)
                guard !cancelled, result.code == 0 else { throw SetupError.authorization }
                let token = try GoogleAuthorization.token(from: result.output)
                values["client_id"] = clientID
                values["client_secret"] = clientSecret
                values["scope"] = readOnly ? "drive.readonly" : "drive"
                values["token"] = token
            case .iCloud:
                // Apple's interactive 2FA flow remains in Terminal. Each account gets its own config.
                try writeConfig(values, storage: storage)
                guard !cancelled else { throw SetupError.authorization }
                try manager.add(storage)
                pending = nil
                manager.showingAddStorage = false
                manager.setup(storage)
                return
            case .s3, .s3Compatible, .cloudflareR2, .idriveE2, .backblazeB2, .gcs, .azureBlob:
                try objectStorageValues(&values, required: required)
            case .other: throw SetupError.missing("provider")
            }
            try writeConfig(values, storage: storage)
            message = "Testing access to this space…"
            try await validate(binary, storage)
            guard !cancelled else { throw SetupError.authorization }
            try manager.add(storage)
            pending = nil
            manager.showingAddStorage = false
            fields = [:]
        } catch {
            if let pending { try? FileManager.default.removeItem(at: pending.configURL(home: home)) }
            message = error.localizedDescription
        }
    }
    // Credential values for every key-based object-storage provider; shared by new connections and credential replacement.
    private func objectStorageValues(_ values: inout [String: String], required: (String, String) throws -> String) throws {
        switch provider {
        case .s3, .s3Compatible, .cloudflareR2, .idriveE2:
            try s3Values(&values, required: required)
        case .backblazeB2:
            values["account"] = try required("account", "application key ID")
            values["key"] = try required("key", "application key")
        case .gcs:
            // New GCS connections use bucket-level IAM, without object ACL grants.
            values["bucket_policy_only"] = "true"
            let file = try required("credential_file", "service-account JSON file")
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "service_account" else { throw SetupError.serviceAccount }
            let compact = try JSONSerialization.data(withJSONObject: object)
            values["service_account_credentials"] = String(decoding: compact, as: UTF8.self)
        case .azureBlob:
            let sas = try required("sas_url", "SAS URL")
            guard let url = URL(string: sas), url.scheme == "https", url.host != nil, url.query != nil else { throw SetupError.endpoint }
            values["sas_url"] = sas
        default: break
        }
    }
    private func requiredField(_ key: String, _ label: String) throws -> String {
        guard let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw SetupError.missing(label) }
        return value
    }
    func load(from storage: Storage) {
        provider = storage.provider
        name = storage.title
        root = storage.root
        readOnly = storage.readOnly
        autoMount = storage.autoMount
        archive = storage.isArchive
        replacingCredentials = false
        tagsText = storage.tags.joined(separator: ", ")
        note = storage.note
        fields = [:]
        message = nil
    }
    /// Saves edited details. New credentials are written first and validated; the previous config is restored if the check fails.
    func saveEdits(_ manager: DriveManager, original: Storage) async {
        guard !working else { return }
        working = true
        message = nil
        defer { working = false }
        let configURL = original.configURL(home: home)
        let previousConfig = try? Data(contentsOf: configURL)
        do {
            let tags = TagInput.parse(tagsText)
            // A mounted drive keeps its name, path, access and credentials; only labels, auto-mount and mode can change.
            if !manager.canEdit(original) {
                let live = try original.updating(title: original.title, root: original.root, readOnly: original.readOnly, autoMount: autoMount, mode: archive ? .archive : .live, tags: tags, note: note, existing: manager.connections)
                try manager.applyLiveEdit(original, with: live)
                manager.spaceToEdit = nil
                return
            }
            let updated = try original.updating(title: name, root: root, readOnly: readOnly, autoMount: autoMount, mode: archive ? .archive : .live, tags: tags, note: note, existing: manager.connections)
            let replacing = replacingCredentials && original.ownConfig && original.provider.isObjectStorage
            if replacing {
                provider = original.provider
                var values = ["type": original.backend]
                try objectStorageValues(&values, required: requiredField)
                try writeConfig(values, storage: updated)
            }
            if (replacing || updated.root != original.root), let binary = manager.rclone {
                message = "Testing access to this space…"
                do { try await validate(binary, updated) }
                catch {
                    if replacing { restoreConfig(previousConfig, at: configURL) }
                    throw error
                }
            }
            try manager.replace(original, with: updated)
            fields = [:]
            manager.spaceToEdit = nil
        } catch {
            message = error.localizedDescription
        }
    }
    private func restoreConfig(_ data: Data?, at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if let data { FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) }
    }
    // Shared by every S3-API provider; only the endpoint and region rules differ per vendor.
    private func s3Values(_ values: inout [String: String], required: (String, String) throws -> String) throws {
        values["provider"] = provider.s3Flavor
        // Setup targets existing buckets; credentials need no bucket-creation rights.
        values["no_check_bucket"] = "true"
        values["access_key_id"] = try required("access_key_id", "access key ID")
        values["secret_access_key"] = try required("secret_access_key", "secret access key")
        if let token = fields["session_token"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty { values["session_token"] = token }
        switch provider {
        case .cloudflareR2:
            guard let account = EndpointInput.r2AccountID(try required("account_id", "Cloudflare account ID")) else { throw SetupError.endpoint }
            values["endpoint"] = "https://\(account).r2.cloudflarestorage.com"
            values["region"] = "auto"
        case .s3Compatible, .idriveE2:
            let endpoint = EndpointInput.https(try required("endpoint", "HTTPS endpoint"))
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw SetupError.endpoint }
            values["endpoint"] = endpoint
            if provider == .s3Compatible { values["region"] = fields["region"]?.isEmpty == false ? fields["region"] : "us-east-1" }
        default:
            values["region"] = fields["region"]?.isEmpty == false ? fields["region"] : "us-east-1"
        }
    }
    private func validate(_ binary: URL, _ storage: Storage) async throws {
        let args = ["lsf", storage.remotePath, "--max-depth", "1", "--dirs-only", "--retries", "1", "--low-level-retries", "1", "--contimeout", "10s", "--timeout", "15s"] + storage.configArguments(home: home)
        let result = try await runCommand(binary, args)
        guard result.code == 0 else { throw SetupError.access }
    }
}

enum SetupError: LocalizedError {
    case missing(String), noGoogleClient, authorization, access, endpoint, lineBreak, serviceAccount
    var errorDescription: String? {
        switch self {
        case .missing(let field): return "Please provide \(field)."
        case .noGoogleClient: return "No reusable Google app credentials were found in the default configuration. Turn off reuse and enter a desktop OAuth client ID and secret."
        case .authorization: return "Browser authorization was cancelled, timed out, or failed. Try again."
        case .access: return "Access test failed. Check your network, credentials, bucket/container name, and read permissions. Nothing was uploaded."
        case .endpoint: return "Enter a valid HTTPS endpoint or SAS URL."
        case .lineBreak: return "Credential fields cannot contain line breaks."
        case .serviceAccount: return "Choose a Google service-account JSON credential file."
        }
    }
}

struct AddStorageView: View {
    @ObservedObject var manager: DriveManager
    @StateObject private var draft = ConnectionDraft()
    private let steps = ["Choose storage", "Connect account", "Review & add"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 25) {
                Label("openshelf", systemImage: "cloud.fill").font(.system(size: 18, weight: .bold, design: .rounded))
                    .padding(.bottom, 20)
                ForEach(0..<3) { index in
                    HStack(spacing: 11) {
                        ZStack {
                            Circle().fill(draft.step == index ? ShelfTheme.ink : Color.white.opacity(0.8)).frame(width: 28, height: 28)
                            if draft.step > index { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                            else { Text(String(index + 1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(draft.step == index ? Color.white : ShelfTheme.muted) }
                        }
                        Text(steps[index]).font(.system(size: 12, weight: draft.step == index ? .semibold : .regular))
                            .foregroundStyle(draft.step == index ? ShelfTheme.ink : ShelfTheme.muted)
                    }
                }
                Spacer()
                Image(systemName: "square.stack.3d.up").font(.system(size: 36, weight: .light)).foregroundStyle(ShelfTheme.color(draft.provider))
                Text("Bring your\nown storage.").font(.system(size: 24, weight: .medium, design: .rounded)).tracking(-0.5)
                Text("Your buckets. Your accounts.\nOne familiar Finder.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).lineSpacing(4)
            }.padding(25).frame(width: 180).background(Color(red: 0.93, green: 0.925, blue: 0.89))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.step == 0 ? "Bring your own storage." : draft.step == 1 ? "Let’s connect your storage." : "Ready for your new space?")
                            .font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.6)
                        Text(draft.step == 0 ? "Choose where your files live." : draft.step == 1 ? "Only the details this provider needs." : "Check access and startup preferences before connecting.")
                            .font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Button { draft.cancel(); manager.showingAddStorage = false } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).padding(8).background(Color.white, in: Circle()) }
                        .buttonStyle(.plain).accessibilityLabel("Cancel setup").help("Cancel setup")
                        .disabled(draft.working && draft.provider != .googleDrive)
                }.padding(25)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if draft.step == 0 { providerSelection }
                        else if draft.step == 1 { connectionDetails }
                        else { review }
                    }.padding(.horizontal, 25).padding(.bottom, 20).disabled(draft.working)
                }
                if let message = draft.message {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: draft.working ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 12)).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ShelfTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
                        .padding(.horizontal, 25).padding(.bottom, 12)
                }
                Divider().opacity(0.5)
                HStack {
                    if draft.step > 0 {
                        Button { draft.step -= 1; draft.message = nil } label: { Label("Back", systemImage: "arrow.left") }
                            .buttonStyle(ShelfButtonStyle()).disabled(draft.working)
                    } else {
                        Text("STEP 1 OF 3").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    if draft.working { ProgressView().controlSize(.small) }
                    Button {
                        if draft.step == 0 { draft.step = 1; draft.message = nil }
                        else if draft.step == 1 { advanceToReview() }
                        else { Task { await draft.connect(manager) } }
                    } label: {
                        HStack(spacing: 10) { Text(actionTitle); if !draft.working { Image(systemName: "arrow.right") } }
                    }.buttonStyle(ShelfButtonStyle(prominent: true)).disabled(draft.working)
                }.padding(20)
            }
        }.frame(width: 880, height: 690).background(ShelfTheme.paper).foregroundStyle(ShelfTheme.ink).preferredColorScheme(.light)
            .task { await draft.loadRemotes(manager) }.interactiveDismissDisabled(draft.working)
    }
    private var actionTitle: String {
        if draft.working { return "Connecting…" }
        if draft.step < 2 { return "Continue" }
        if draft.importing { return "Test & add space" }
        if draft.provider == .googleDrive { return "Sign in with Google" }
        if draft.provider == .iCloud { return "Continue to Apple sign-in" }
        return "Test & add space"
    }
    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PERSONAL CLOUD & OBJECT STORAGE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(ShelfTheme.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Provider.selectable) { provider in
                    Button {
                        draft.provider = provider
                        draft.archive = provider.prefersArchive
                        draft.autoMount = !provider.prefersArchive
                        draft.importing = false
                        draft.message = nil
                    } label: {
                        HStack(spacing: 11) {
                            ProviderBadge(provider: provider, size: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.leading)
                                Text(provider.isObjectStorage ? (provider.freeTierBytes != nil ? "Archive · 10 GB free" : "Archive · buckets") : "Files & folders").font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                            }
                            Spacer(minLength: 0)
                            if draft.provider == provider && !draft.importing { Image(systemName: "checkmark.circle.fill").foregroundStyle(ShelfTheme.color(provider)).font(.system(size: 13)) }
                        }.padding(14).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(draft.provider == provider && !draft.importing ? ShelfTheme.color(provider) : ShelfTheme.ink.opacity(0.07), lineWidth: draft.provider == provider && !draft.importing ? 1.5 : 1))
                    }.buttonStyle(.plain).accessibilityLabel("Choose " + provider.title)
                }
            }
            Button { draft.importing.toggle(); draft.message = nil } label: {
                HStack(spacing: 12) {
                    Image(systemName: "link").font(.system(size: 17)).frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use a saved connection").font(.system(size: 12, weight: .semibold))
                        Text("Import another provider already configured in rclone.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Image(systemName: draft.importing ? "checkmark.circle.fill" : "arrow.right")
                }.padding(16).background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(draft.importing ? ShelfTheme.ink : ShelfTheme.ink.opacity(0.07)))
            }.buttonStyle(.plain)
            Label("Your existing connections and files stay in place.", systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
    }
    private var connectionDetails: some View {
        VStack(spacing: 16) {
            ShelfSection(title: "Your space", subtitle: "Give this account or folder a name you’ll recognize.") {
                if draft.importing {
                    Picker("Saved connection", selection: $draft.selectedRemote) {
                        ForEach(draft.remotes, id: \.name) { Text($0.name + " · " + $0.type).tag($0.name) }
                    }.controlSize(.large)
                    if draft.remotes.isEmpty { Text("No saved connections found in the default rclone configuration.").font(.caption).foregroundStyle(ShelfTheme.muted) }
                } else {
                    HStack { ProviderBadge(provider: draft.provider, size: 30); Text(draft.provider.title).font(.system(size: 13, weight: .medium)); Spacer() }
                }
                field("Space name", text: $draft.name, prompt: "Personal, Work, Media Archive…")
                field(draft.provider.isObjectStorage && !draft.importing ? "Bucket or container / optional prefix" : "Folder path (optional)", text: $draft.root, prompt: draft.provider.isObjectStorage && !draft.importing ? "my-bucket/footage" : "Leave blank for the account root")
            }
            if !draft.importing, let guide = draft.provider.guide {
                ShelfSection(title: "Set up " + draft.provider.title, subtitle: "Follow these steps, then fill in the connection below.") {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(index + 1)).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                                .background(ShelfTheme.accent.opacity(0.5), in: Circle())
                            Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let url = guide.consoleURL, !guide.consoleLabel.isEmpty {
                        Button { NSWorkspace.shared.open(url) } label: { Label(guide.consoleLabel, systemImage: "arrow.up.right.square") }
                            .buttonStyle(ShelfButtonStyle())
                    }
                    if let note = draft.provider.egressNote { Label(note, systemImage: "dollarsign.circle").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted) }
                }
            }
            if !draft.importing {
                ShelfSection(title: "Connection", subtitle: draft.provider == .googleDrive ? "Sign in in your browser after the next step." : "Use credentials scoped to the storage you want to access.") { providerFields }
            }
        }
    }
    private var review: some View {
        VStack(spacing: 16) {
            ShelfSection(title: draft.name, subtitle: draft.importing ? "Saved connection · " + draft.selectedRemote : draft.provider.title) {
                HStack {
                    Label(draft.root.isEmpty ? "Account root" : draft.root, systemImage: "folder").font(.system(size: 13)).lineLimit(3)
                    Spacer()
                }
                Text("A separate Finder folder and cache will be created for this space.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            }
            if draft.provider.prefersArchive {
                ShelfSection(title: "Use as archive", subtitle: "Recommended for object storage.") {
                    Toggle("Archive mode", isOn: $draft.archive).toggleStyle(.switch).controlSize(.small)
                    Text(draft.archive ? "Opening a file downloads it once and caches it locally, which avoids repeat downloads. Auto-mount is off by default." : "Live mode behaves like a normal drive and may repeatedly download files you open.")
                        .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if let note = draft.provider.egressNote { Label(note, systemImage: "dollarsign.circle").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted) }
                }.font(.system(size: 13))
            }
            ShelfSection(title: "Make it work your way", subtitle: "You can change automatic mounting later on the space card.") {
                Toggle("Mount automatically at startup", isOn: $draft.autoMount).toggleStyle(.switch).controlSize(.small)
                Divider().opacity(0.5)
                Toggle("Read-only access", isOn: $draft.readOnly).toggleStyle(.switch).controlSize(.small)
                Text("Read-only prevents changes through this Finder space.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }.font(.system(size: 13))
            VStack(alignment: .leading, spacing: 10) {
                if draft.provider.isObjectStorage && !draft.importing {
                    Label("Provider charges for downloads and requests may apply. The connection test only reads metadata.", systemImage: "info.circle")
                }
                Label("Credentials stay in protected local rclone files. OpenShelf does not add an encryption layer or use Keychain.", systemImage: "lock.shield")
            }.font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func advanceToReview() {
        do {
            _ = try Storage.make(provider: draft.provider, title: draft.name, root: draft.root, existing: manager.connections, readOnly: draft.readOnly, autoMount: draft.autoMount)
            if draft.importing {
                guard !draft.selectedRemote.isEmpty else { throw SetupError.missing("saved connection") }
            } else {
                if draft.provider.isObjectStorage && draft.root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SetupError.missing("bucket or container") }
                let required: [String]
                switch draft.provider {
                case .googleDrive: required = draft.reuseGoogleClient ? [] : ["client_id", "client_secret"]
                case .s3: required = ["access_key_id", "secret_access_key"]
                case .s3Compatible, .idriveE2: required = ["endpoint", "access_key_id", "secret_access_key"]
                case .cloudflareR2: required = ["account_id", "access_key_id", "secret_access_key"]
                case .backblazeB2: required = ["account", "key"]
                case .gcs: required = ["credential_file"]
                case .azureBlob: required = ["sas_url"]
                default: required = []
                }
                if required.contains(where: { (draft.fields[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    draft.message = "Complete the required connection fields before continuing."
                    return
                }
            }
            draft.message = nil
            draft.step = 2
        } catch { draft.message = error.localizedDescription }
    }
    private var providerFields: some View { ProviderFields(draft: draft) }
    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View { inputField(title, text: text, prompt: prompt) }
    private func secret(_ title: String, text: Binding<String>) -> some View { secretField(title, text: text) }
}

func inputField(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(title).font(.system(size: 12, weight: .medium))
        TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 13)).padding(12)
            .background(ShelfTheme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ShelfTheme.ink.opacity(0.12)))
            .accessibilityLabel(title)
    }
}

func secretField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(title).font(.system(size: 12, weight: .medium))
        SecureField(title, text: text).textFieldStyle(.plain).font(.system(size: 13)).padding(12)
            .background(ShelfTheme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ShelfTheme.ink.opacity(0.12)))
            .accessibilityLabel(title)
    }
}

struct ProviderFields: View {
    @ObservedObject var draft: ConnectionDraft
    var body: some View {
        switch draft.provider {
        case .googleDrive:
            Toggle("Reuse Google app credentials already on this Mac", isOn: $draft.reuseGoogleClient)
            if !draft.reuseGoogleClient {
                inputField("Desktop OAuth client ID", text: draft.value("client_id"))
                secretField("Desktop OAuth client secret", text: draft.value("client_secret"))
            }
            Text("Each account signs in separately in your browser. Reusing app credentials does not copy account tokens. Your Google project must allow the additional account as a test user when in Testing mode.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .iCloud:
            Text("Apple sign-in and 2FA open in Terminal. This experimental connector needs periodic reauthentication. Each Apple account has its own configuration and Finder location.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .s3, .s3Compatible:
            if draft.provider == .s3Compatible { inputField("HTTPS endpoint", text: draft.value("endpoint"), prompt: "https://…") }
            inputField("Region", text: draft.value("region"), prompt: "us-east-1")
            inputField("Access key ID", text: draft.value("access_key_id"))
            secretField("Secret access key", text: draft.value("secret_access_key"))
            secretField("Session token (optional)", text: draft.value("session_token"))
        case .cloudflareR2:
            inputField("Cloudflare account ID", text: draft.value("account_id"), prompt: "32-character ID from the R2 overview page")
            inputField("Access key ID", text: draft.value("access_key_id"))
            secretField("Secret access key", text: draft.value("secret_access_key"))
            Text("Create an R2 API token scoped to this bucket (Object Read & Write). The endpoint is built from your account ID.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .backblazeB2:
            inputField("Application key ID", text: draft.value("account"))
            secretField("Application key", text: draft.value("key"))
            Text("Use an application key restricted to this bucket rather than your master key.").font(.caption).foregroundStyle(.secondary)
        case .idriveE2:
            inputField("HTTPS endpoint", text: draft.value("endpoint"), prompt: "https://….idrivee2-….com")
            inputField("Access key ID", text: draft.value("access_key_id"))
            secretField("Secret access key", text: draft.value("secret_access_key"))
            Text("Copy the endpoint shown for your bucket's region in the IDrive e2 dashboard.").font(.caption).foregroundStyle(.secondary)
        case .gcs:
            HStack {
                Text(draft.fields["credential_file"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Service-account JSON credentials")
                Spacer()
                Button("Choose file…") { draft.chooseCredentialFile() }
            }
            Text("The service account needs access to the selected bucket. GCS is separate from your Google Drive subscription.").font(.caption).foregroundStyle(.secondary)
        case .azureBlob:
            secretField("Scoped SAS URL", text: draft.value("sas_url"))
            Text("Use a SAS URL granting the access you want for this container. Read-only mounts still need read/list permissions.").font(.caption).foregroundStyle(.secondary)
        case .other: EmptyView()
        }
    }
}

struct EditStorageView: View {
    @ObservedObject var manager: DriveManager
    let storage: Storage
    @StateObject private var draft = ConnectionDraft()
    private var canReplaceCredentials: Bool { storage.ownConfig && storage.provider.isObjectStorage }
    private var locked: Bool { !manager.canEdit(storage) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProviderBadge(provider: storage.provider, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit details").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(storage.provider.title).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                }
            }
            ScrollView {
                VStack(spacing: 16) {
                    ShelfSection(title: "Labels", subtitle: "Shown on the card and searchable. Safe to change any time.") {
                        inputField("Tags (comma separated)", text: $draft.tagsText, prompt: "work, family, backup")
                        inputField("Note", text: $draft.note, prompt: "What is this space for?")
                    }
                    ShelfSection(title: "Space", subtitle: locked ? "Disconnect this drive to change its name, location, access or credentials." : "Changes apply the next time this drive is mounted.") {
                        Group {
                            inputField("Space name", text: $draft.name)
                            inputField(storage.provider.isObjectStorage ? "Bucket or container / optional prefix" : "Folder path (optional)", text: $draft.root, prompt: storage.provider.isObjectStorage ? "my-bucket/footage" : "Leave blank for the account root")
                            Toggle("Read-only", isOn: $draft.readOnly)
                        }.disabled(locked).opacity(locked ? 0.55 : 1)
                        if storage.provider == .googleDrive && !storage.readOnly {
                            Text("This account may have been signed in with read-only access. If saving fails to write, use Reconnect.").font(.caption).foregroundStyle(ShelfTheme.muted)
                        }
                        Toggle("Mount automatically at login", isOn: $draft.autoMount)
                        if storage.provider.prefersArchive {
                            Toggle("Archive mode (avoid repeated downloads)", isOn: $draft.archive)
                        }
                    }
                    if canReplaceCredentials && !locked {
                        ShelfSection(title: "Credentials", subtitle: "Saved credentials are never shown. Replace them to rotate keys.") {
                            Toggle("Replace credentials", isOn: $draft.replacingCredentials)
                            if draft.replacingCredentials { ProviderFields(draft: draft) }
                        }
                    }
                }
            }
            if let message = draft.message { Text(message).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { manager.spaceToEdit = nil }.buttonStyle(ShelfButtonStyle())
                Button(draft.working ? "Saving…" : "Save") { Task { await draft.saveEdits(manager, original: storage) } }
                    .buttonStyle(ShelfButtonStyle(prominent: true)).disabled(draft.working)
            }
        }.padding(26).frame(width: 520, height: 600).background(ShelfTheme.paper)
            .onAppear { draft.load(from: storage) }
    }
}
