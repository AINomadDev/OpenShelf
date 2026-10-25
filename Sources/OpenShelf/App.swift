import SwiftUI
import AppKit

private let ink = Color(red: 0.14, green: 0.15, blue: 0.13)
private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
private let accent = Color(red: 0.98, green: 0.84, blue: 0.27)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: DriveManager?
    // Drives run as independent background jobs, so quitting never interrupts transfers.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        manager?.authenticationProcess?.terminate()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OpenShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = DriveManager()
    var body: some Scene {
        Window("OpenShelf", id: "dashboard") {
            Dashboard(manager: manager)
                .onAppear {
                    delegate.manager = manager
                    manager.startMonitoring()
                }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("OpenShelf", systemImage: "externaldrive.badge.icloud") {
            MenuContent(manager: manager)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var manager: DriveManager
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open OpenShelf") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        ForEach(manager.connections) { storage in
            Button("\(manager.mounted.contains(storage) ? "Open" : "Connect") \(storage.title)") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if manager.mounted.contains(storage) { manager.open(storage) }
            }
        }
        Divider()
        Button(manager.loginStatus) { manager.openLoginSettings() }
        Button("Quit OpenShelf") { NSApplication.shared.terminate(nil) }.disabled(manager.blocksQuit)
    }
}

struct Dashboard: View {
    @ObservedObject var manager: DriveManager
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your spaces").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.8)
                        Text("Bring your own storage. Every account in one Finder.").font(.system(size: 13)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Button { manager.showingAddStorage = true } label: { Label("Add storage", systemImage: "plus") }
                        .buttonStyle(ShelfButtonStyle(prominent: true))
                }.padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            metric("\(manager.mounted.count) / \(manager.connections.count)", label: "Spaces mounted", symbol: "externaldrive.badge.checkmark")
                            metric(ByteCountFormatter.string(fromByteCount: manager.activity.values.reduce(0) { $0 + $1.diskCache.bytesUsed }, countStyle: .file), label: "Mounted cache", symbol: "internaldrive")
                            metric(manager.diskSpace.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Checking", label: "Free on your Mac", symbol: "leaf")
                        }
                        usagePanel
                        if let warning = manager.diskSpace.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ShelfTheme.accent.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        }
                        HStack(spacing: 12) {
                            HStack(spacing: 9) {
                                Image(systemName: "magnifyingglass").foregroundStyle(ShelfTheme.muted)
                                TextField("Search accounts or folders", text: $manager.searchText).textFieldStyle(.plain)
                                    .accessibilityLabel("Search spaces")
                                if !manager.searchText.isEmpty {
                                    Button { manager.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search")
                                }
                            }.font(.system(size: 13)).padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(ink.opacity(0.08)))
                            Menu {
                                Button("All providers") { manager.providerFilter = nil }
                                ForEach(Provider.allCases) { provider in
                                    Button(provider.title) { manager.providerFilter = provider }
                                }
                            } label: { Label(manager.providerFilter?.title ?? "All providers", systemImage: "line.3.horizontal.decrease") }
                                .menuStyle(.borderlessButton).fixedSize()
                                .font(.system(size: 13, weight: .semibold)).padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(ink.opacity(0.08)))
                            Button { Task { await manager.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(ShelfButtonStyle()).disabled(manager.refreshing).help("Refresh connection status")
                                .accessibilityLabel("Refresh connection status")
                        }
                        HStack {
                            Text("\(manager.visibleConnections.count) spaces").font(.system(size: 12, weight: .medium)).foregroundStyle(ShelfTheme.muted)
                            Spacer()
                            Toggle("Mounted only", isOn: $manager.mountedOnly).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                        }
                        if manager.visibleConnections.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(ShelfTheme.muted)
                                Text(manager.connections.isEmpty ? "Make room for your files" : "No matching spaces").font(.system(size: 18, weight: .semibold))
                                Text(manager.connections.isEmpty ? "Connect your first account to get started." : "Try another search or reset your filters.").font(.system(size: 13)).foregroundStyle(ShelfTheme.muted)
                                Button(manager.connections.isEmpty ? "Add storage" : "Reset filters") {
                                    if manager.connections.isEmpty { manager.showingAddStorage = true } else { manager.showAllSpaces() }
                                }.buttonStyle(ShelfButtonStyle())
                            }.padding(32).frame(maxWidth: .infinity).background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(manager.visibleConnections) { StorageCard(storage: $0, manager: manager) }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                            Text("5 GiB cache target per space · 10 GiB free-space target. Active files and pending uploads can exceed these targets. Archive-mode spaces keep downloaded files cached longer to avoid paying for repeat downloads.")
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).padding(.top, 4)
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
        }.frame(minWidth: 1000, minHeight: 710).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .sheet(isPresented: $manager.showingGuide) { setupGuide }
        .sheet(isPresented: $manager.showingAddStorage) { AddStorageView(manager: manager) }
        .sheet(item: $manager.spaceToEdit) { EditStorageView(manager: manager, storage: $0) }
        .sheet(isPresented: $manager.showingActivity) { activityPanel }
        .confirmationDialog("Open this archive in Finder?", isPresented: Binding(get: { manager.archiveToOpen != nil }, set: { if !$0 { manager.archiveToOpen = nil } }), titleVisibility: .visible) {
            Button("Open in Finder") {
                if let storage = manager.archiveToOpen { manager.open(storage) }
                manager.archiveToOpen = nil
            }
        } message: { Text((manager.archiveToOpen?.provider.egressNote ?? "Downloads may be billed by your provider.") + " Finder previews, Spotlight, and playing media read file contents. Prefer copying files in rather than browsing them.") }
        .confirmationDialog("Remove this saved space?", isPresented: Binding(get: { manager.spaceToRemove != nil }, set: { if !$0 { manager.spaceToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove space", role: .destructive) {
                if let storage = manager.spaceToRemove { manager.remove(storage) }
                manager.spaceToRemove = nil
            }
        } message: { Text("Cloud files, account credentials, and cached data are kept. Only the local saved space is removed.") }
        .alert("OpenShelf", isPresented: Binding(get: { manager.notice != nil }, set: { if !$0 { manager.notice = nil } })) {
            Button("OK") { manager.notice = nil }
        } message: { Text(manager.notice ?? "") }
    }
    private var usagePanel: some View {
        let rows = manager.connections.filter { manager.configured.contains($0) || manager.usage[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage usage").font(.system(size: 16, weight: .semibold))
                    Text("Archive object storage and watch your free allowance. Figures are cached to limit billed list requests.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
                Spacer()
                Button { manager.refreshAllUsage() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(ShelfButtonStyle()).disabled(!manager.usageRefreshing.isEmpty || rows.isEmpty)
            }
            if rows.isEmpty {
                Text("Usage appears once a space is connected.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            }
            ForEach(rows) { storage in
                let value = manager.usage[storage.id]
                let quota = storage.quota(for: value)
                HStack(spacing: 12) {
                    ProviderBadge(provider: storage.provider, size: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(storage.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if storage.isArchive { Text("ARCHIVE").font(.system(size: 8, weight: .bold)).tracking(0.8).padding(.horizontal, 5).padding(.vertical, 2).background(ShelfTheme.accent.opacity(0.5), in: Capsule()) }
                            Spacer()
                            if manager.usageRefreshing.contains(storage.id) { ProgressView().controlSize(.mini) }
                            else if let quota { Text(UsageText.summary(quota, freeTier: storage.provider.freeTierBytes != nil && value?.totalBytes == nil, accountName: value?.accountWide == true ? storage.provider.accountName : nil)).font(.system(size: 11)).foregroundStyle(quota.level == .exceeded ? Color.red : ShelfTheme.muted) }
                            else if value?.isReported == false { Text(UsageText.unreported(value)).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).help("This provider does not expose storage totals for this space (iCloud Drive and Google Shared Drives).") }
                            else { Text("Measuring…").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted) }
                        }
                        if let quota, quota.limit != nil { UsageBar(quota: quota) } else { Color.clear.frame(height: 6) }
                    }
                }
            }
            if rows.contains(where: { $0.provider.freeTierBytes != nil }) {
                Label("The 10 GB free tier is per provider account, so spaces sharing an account add up. Beyond it, pay-as-you-go applies.", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.fill").font(.system(size: 21)).frame(width: 41, height: 41).background(accent, in: RoundedRectangle(cornerRadius: 13))
                Text("openshelf").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(-0.7)
            }.padding(.bottom, 10)
            VStack(spacing: 7) {
                Button { manager.showAllSpaces() } label: {
                    HStack { Label("My spaces", systemImage: "square.grid.2x2.fill"); Spacer(); Text(String(manager.connections.count)).opacity(0.5) }
                        .font(.system(size: 13, weight: .semibold)).padding(12).background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain)
                nav("Activity", symbol: "waveform.path") { manager.showingActivity = true }
                nav("Getting started", symbol: "book.closed") { manager.showingGuide = true }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("YOUR ACCOUNTS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(ShelfTheme.muted)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(manager.connections) { storage in
                            Button { manager.showAllSpaces(); manager.searchText = storage.title } label: {
                                HStack(spacing: 9) {
                                    ProviderBadge(provider: storage.provider, size: 27)
                                    Text(storage.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Circle().fill(manager.mounted.contains(storage) ? Color.green : ShelfTheme.muted.opacity(0.3)).frame(width: 5, height: 5)
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 210)
            }.padding(.horizontal, 8)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "leaf").font(.system(size: 24)).foregroundStyle(ShelfTheme.color(.googleDrive))
                Text("Room for what’s next.").font(.system(size: 16, weight: .medium, design: .rounded))
                Text("Your storage. Your bill. Your Mac.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 15))
            Button { manager.openLoginSettings() } label: {
                Label(manager.loginStatus, systemImage: "power").font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).foregroundStyle(ShelfTheme.muted)
        }.padding(20).frame(width: 200).frame(maxHeight: .infinity).background(Color.white.opacity(0.5))
            .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.07)).frame(width: 1) }
    }
    private func nav(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 13)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
    }
    private func metric(_ value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(ShelfTheme.muted).frame(width: 38, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.6)
                Text(label).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }
            Spacer(minLength: 0)
        }.padding(15).frame(maxWidth: .infinity).background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
    }
    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live activity").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Current transfer and cache status across your spaces.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                }
                Spacer()
                Button("Done") { manager.showingActivity = false }.buttonStyle(ShelfButtonStyle())
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(manager.connections) { storage in
                        ShelfSection(title: storage.title, subtitle: storage.provider.title) {
                            if let stats = manager.activity[storage] {
                                HStack {
                                    Label("\(stats.diskCache.uploadsInProgress) uploading", systemImage: "arrow.up.circle")
                                    Spacer()
                                    Text("\(stats.diskCache.uploadsQueued) queued · \(stats.diskCache.erroredFiles) errors")
                                }.font(.system(size: 12))
                                Text(ByteCountFormatter.string(fromByteCount: stats.diskCache.bytesUsed, countStyle: .file) + " cached locally").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                            } else {
                                Text(manager.mounted.contains(storage) ? "Waiting for transfer status…" : "Not mounted").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                            }
                        }
                    }
                }
            }
            Text("Live status only. A mounted drive does not establish that every file is synced.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }.padding(28).frame(width: 650, height: 580).background(paper)
    }
    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bring your own storage.").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("1. Choose a provider, name your space, and review access and startup preferences.")
            Text("2. Sign in with Google in your browser, finish Apple sign-in in Terminal, or provide scoped object-storage credentials (S3, GCS, Azure, Cloudflare R2, Backblaze B2, IDrive e2).")
            Text("3. Object storage defaults to Archive mode: copy files in, and open them only when needed to avoid download fees. Use Activity to check transfers before disconnecting.")
            Text("Google accounts can reuse saved app credentials. iCloud is experimental and needs periodic reauthentication. OpenShelf adds no encryption layer.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            HStack {
                Button("Full setup guide") { if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) } }.buttonStyle(ShelfButtonStyle())
                Spacer()
                Button("Got it") { manager.showingGuide = false }.buttonStyle(ShelfButtonStyle(prominent: true))
            }
        }.font(.system(size: 14)).lineSpacing(5).padding(32).frame(width: 540).background(paper)
    }
}

struct StorageCard: View {
    let storage: Storage
    @ObservedObject var manager: DriveManager
    private var isMounted: Bool { manager.mounted.contains(storage) }
    private var isConfigured: Bool { manager.configured.contains(storage) }
    private var isBusy: Bool { manager.busy.contains(storage) }
    private var statusText: String { isBusy ? "Connecting" : isMounted ? "Mounted" : isConfigured ? "Saved" : "Not connected" }
    private var subtitle: String { storage.provider.title + (storage.root.isEmpty ? "" : " · " + storage.root) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 8) { identity; modeRow }.padding(.top, 14)
            usageBlock.padding(.top, 16)
            Spacer(minLength: 14)
            footer
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(ink.opacity(0.075)))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(provider: storage.provider, size: 42)
                Text(storage.title).font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(-0.3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).help(storage.title)
                actionMenu
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(storage.provider.title + (storage.provider.platformName.map { " · " + $0 } ?? "")).font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.8)).lineLimit(1)
                    Text(storage.root.isEmpty ? "Account root" : storage.root).font(.system(size: 10, design: .monospaced)).foregroundStyle(ShelfTheme.muted)
                        .lineLimit(1).truncationMode(.middle).help(storage.root)
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(isMounted ? Color.green : ShelfTheme.muted.opacity(0.5)).frame(width: 6, height: 6)
                    Text(statusText)
                }.font(.system(size: 10, weight: .medium)).fixedSize().padding(.horizontal, 9).padding(.vertical, 5)
                    .background(isMounted ? Color.green.opacity(0.09) : paper, in: Capsule())
            }
        }
    }
    private var actionMenu: some View {
        Menu {
            Button("Edit details…") { manager.spaceToEdit = storage }
            if manager.usage[storage.id]?.isReported == false {
                Button("Measure size now") { manager.measureSize(storage) }.disabled(manager.usageRefreshing.contains(storage.id))
            }
            Button("Copy Finder path") { manager.copyPath(storage) }
            Button("View log") { manager.showLog(storage) }
            if storage.provider.prefersArchive {
                Button(storage.isArchive ? "Switch to live mode" : "Switch to archive mode") { manager.setMode(storage, storage.isArchive ? .live : .archive) }
            }
            if storage.provider.isObjectStorage {
                Button("Clean junk files (._*, .DS_Store)") { manager.cleanJunk(storage) }.disabled(isMounted || manager.isRunning(storage) || isBusy)
            }
            Divider()
            Button("Remove space…", role: .destructive) { manager.spaceToRemove = storage }.disabled(isMounted || manager.isRunning(storage) || isBusy)
        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Space actions")
    }
    // Account line, tags and note share one block so every card starts its usage panel at a similar height.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let who = manager.identities[storage.id], let line = who.email ?? who.detail {
                HStack(spacing: 6) {
                    Image(systemName: who.email != nil ? "person.crop.circle" : "server.rack").frame(width: 14)
                    Text(who.name.map { $0 + " · " + line } ?? line).lineLimit(1).truncationMode(.middle)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.75)).help(line)
            }
            if !storage.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(storage.tags.prefix(4), id: \.self) { Text($0).font(.system(size: 9, weight: .semibold)).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3).background(ShelfTheme.accent.opacity(0.45), in: Capsule()) }
                }
            }
            if !storage.note.isEmpty { Text(storage.note).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(2) }
        }
    }
    private var modeRow: some View {
        HStack(spacing: 6) {
            chip(storage.isArchive ? "archivebox" : "bolt", storage.isArchive ? "Archive" : "Live", tint: storage.isArchive && storage.provider.chargesEgress ? .orange : nil)
            chip(storage.readOnly ? "lock" : "pencil", storage.readOnly ? "Read-only" : "Read & write")
            Spacer(minLength: 4)
            Toggle("Auto-mount", isOn: Binding(get: { storage.autoMount }, set: { manager.setAutoMount(storage, enabled: $0) })).toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).fixedSize()
        }
    }
    private func chip(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize().foregroundStyle(tint ?? ShelfTheme.muted)
            .padding(.horizontal, 8).padding(.vertical, 4).background((tint ?? ShelfTheme.muted).opacity(0.1), in: Capsule())
    }
    private func archiveCaption(_ caption: String?) -> String {
        guard storage.isArchive else { return caption ?? " " }
        return (caption.map { $0 + " · " } ?? "") + (storage.provider.chargesEgress ? "downloads may cost money" : "no egress fees")
    }
    private var usageBlock: some View {
        let value = manager.usage[storage.id]
        return VStack(alignment: .leading, spacing: 9) {
            if let quota = storage.quota(for: value) {
                let parts = UsageBreakdown.make(quota, freeTier: storage.provider.freeTierBytes != nil && value?.totalBytes == nil, accountName: value?.accountWide == true ? storage.provider.accountName : nil)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(parts.used).font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.4).foregroundStyle(quota.level == .exceeded ? Color.red : ink)
                    if let limit = parts.limit { Text(limit).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted) }
                    Spacer(minLength: 4)
                    if let remaining = parts.remaining { Text(remaining).font(.system(size: 12, weight: .semibold)).foregroundStyle(quota.level == .warning ? Color.orange : ink) }
                }
                if quota.limit != nil { UsageBar(quota: quota) } else { Color.clear.frame(height: 6) }
                Text(parts.warning ?? archiveCaption(parts.caption)).font(.system(size: 10)).foregroundStyle(parts.warning != nil ? Color.red : ShelfTheme.muted).lineLimit(2)
            } else {
                let unreported = value?.isReported == false
                Text(unreported ? (value?.measured == true ? UsageText.bytes(value?.usedBytes ?? 0) : "—") : "…").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(unreported && value?.measured != true ? ShelfTheme.muted : ink)
                Color.clear.frame(height: 6)
                Text(unreported ? (value?.measured == true ? "Measured by listing files" : "Total not reported · ⋯ › Measure size") : "Measuring storage…").font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
            }
            Divider().opacity(0.5)
            if let stats = manager.activity[storage] {
                let pending = stats.diskCache.uploadsInProgress + stats.diskCache.uploadsQueued
                HStack(spacing: 0) {
                    stat(ByteCountFormatter.string(fromByteCount: stats.diskCache.bytesUsed, countStyle: .file), "cached")
                    Spacer()
                    stat(pending > 0 ? "\(pending) pending" : stats.diskCache.outOfSpace || stats.diskCache.erroredFiles > 0 ? "Needs attention" : "None", "uploads", tint: pending > 0 ? .orange : (stats.diskCache.outOfSpace || stats.diskCache.erroredFiles > 0 ? .red : nil), trailing: true)
                }
            } else {
                Text(manager.statuses[storage] ?? (isConfigured ? "Ready when you are." : "Connect this account to get started."))
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
        }
    }
    private func stat(_ value: String, _ label: String, tint: Color? = nil, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint ?? ink)
            Text(label).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if isMounted { if storage.isArchive && storage.provider.chargesEgress { manager.archiveToOpen = storage } else { manager.open(storage) } }
                else if isConfigured { Task { await manager.mount(storage) } }
                else { manager.setup(storage) }
            } label: {
                HStack {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(isMounted ? "Open in Finder" : isBusy ? "Connecting…" : isConfigured ? "Mount drive" : "Connect").lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: isMounted ? "arrow.up.right" : "arrow.right")
                }
            }.buttonStyle(ShelfButtonStyle(prominent: true)).disabled(isBusy || manager.rclone == nil || (manager.isRunning(storage) && !isMounted))
            Button(isMounted ? "Disconnect" : "Reconnect") {
                if isMounted { Task { await manager.unmount(storage) } } else { manager.setup(storage) }
            }.buttonStyle(ShelfButtonStyle()).disabled(isBusy || (!isMounted && (!isConfigured || manager.isRunning(storage))))
        }
    }
}
