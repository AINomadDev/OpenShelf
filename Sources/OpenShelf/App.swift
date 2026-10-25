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
        if manager.connections.contains(where: { $0.provider.pricing != nil }) {
            Text("Est. storage cost: \(PricingInfo.dollars(manager.monthlyTotal)) / month")
        }
        ForEach(manager.connections.filter { manager.activity[$0].map { $0.diskCache.uploadsInProgress + $0.diskCache.uploadsQueued > 0 } == true }) { storage in
            Text("Uploading to \(storage.title)…")
        }
        ForEach(manager.connections.filter { storage in storage.quota(for: manager.usage[storage.id]).map { $0.level == .exceeded || $0.level == .warning } == true }) { storage in
            Text("⚠︎ \(storage.title) is near or over its allowance")
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
            switch manager.page {
            case .activity: ActivityPage(manager: manager)
            case .costs: CostsPage(manager: manager)
            case .spaces:
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
                        totalsPanel
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
            }
        }.frame(minWidth: 1000, minHeight: 710).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .sheet(isPresented: $manager.showingGuide) { setupGuide }
        .sheet(isPresented: $manager.showingAddStorage) { AddStorageView(manager: manager) }
        .sheet(item: $manager.spaceToEdit) { EditStorageView(manager: manager, storage: $0) }
        .confirmationDialog("Open this archive in Finder?", isPresented: Binding(get: { manager.archiveToOpen != nil }, set: { if !$0 { manager.archiveToOpen = nil } }), titleVisibility: .visible) {
            Button("Open in Finder") {
                if let storage = manager.archiveToOpen { manager.open(storage) }
                manager.archiveToOpen = nil
            }
        } message: { Text((manager.archiveToOpen?.provider.egressNote ?? "Downloads may be billed by your provider.") + (manager.archiveToOpen.flatMap { manager.restoreCost($0) }.map { " Reading everything stored here would cost about \(PricingInfo.dollars($0)) in egress." } ?? "") + " Finder previews, Spotlight, and playing media read file contents. Prefer copying files in rather than browsing them.") }
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
    private var insightsSummary: some View {
        let alerts = manager.connections.compactMap { storage -> (Storage, String, Bool)? in
            switch manager.budgetLevel(storage) {
            case .exceeded: return (storage, "\(storage.title) is over its \(PricingInfo.dollars(manager.budgets[storage.id] ?? 0)) monthly budget", true)
            case .nearing: return (storage, "\(storage.title) is near its \(PricingInfo.dollars(manager.budgets[storage.id] ?? 0)) monthly budget", false)
            default:
                if let days = manager.daysUntilFreeTier(storage), days > 0, days <= 60 { return (storage, "\(storage.title) may pass its free tier in about \(days) days at the current growth", false) }
                return nil
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            if manager.connections.contains(where: { $0.provider.pricing != nil }) {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle").foregroundStyle(ShelfTheme.muted)
                    Text("Estimated storage cost: \(PricingInfo.dollars(manager.monthlyTotal)) / month").font(.system(size: 12, weight: .semibold))
                    Text("list prices, excludes requests and egress").font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                }
            }
            ForEach(manager.connections.compactMap { storage in manager.credentialWarning(storage).map { (storage, "\(storage.title): \($0)") } }, id: \.0.id) { item in
                Label(item.1, systemImage: "key.fill").font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            ForEach(alerts, id: \.0.id) { alert in
                Label(alert.1, systemImage: alert.2 ? "exclamationmark.triangle.fill" : "bell.badge").font(.system(size: 11)).foregroundStyle(alert.2 ? Color.red : Color.orange)
            }
        }
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
            insightsSummary
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.fill").font(.system(size: 21)).frame(width: 41, height: 41).background(accent, in: RoundedRectangle(cornerRadius: 13))
                Text("openshelf").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(-0.7)
            }.padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
              VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 4) {
                navItem("My spaces", symbol: "square.grid.2x2.fill", page: .spaces, badge: String(manager.connections.count))
                navItem("Activity", symbol: "waveform.path", page: .activity, badge: manager.activeTransfers > 0 ? "\(manager.activeTransfers)" : nil)
                navItem("Costs & budgets", symbol: "chart.line.uptrend.xyaxis", page: .costs, badge: nil)
                nav("Getting started", symbol: "book.closed") { manager.showingGuide = true }
                Button { manager.showingAddStorage = true } label: { Label("Add storage", systemImage: "plus.circle.fill").font(.system(size: 13, weight: .semibold)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK VIEWS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(ShelfTheme.muted)
                quick("Mounted now", symbol: "externaldrive.badge.checkmark", filter: .mounted, count: manager.mounted.count)
                quick("Archive spaces", symbol: "archivebox", filter: .archive, count: manager.connections.filter(\.isArchive).count)
                quick("Needs attention", symbol: "exclamationmark.triangle", filter: .attention, count: manager.attentionCount, tint: manager.attentionCount > 0 ? .orange : nil)
            }.padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR ACCOUNTS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(ShelfTheme.muted)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(accountTypes, id: \.self) { provider in
                            Button { manager.showAllSpaces(); manager.providerFilter = provider } label: {
                                HStack(spacing: 10) {
                                    ProviderBadge(provider: provider, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        Text(accountCaption(provider)).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Circle().fill(manager.mounted.contains { $0.provider == provider } ? Color.green : ShelfTheme.muted.opacity(0.3)).frame(width: 7, height: 7)
                                }.padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Show \(provider.title) spaces")
                        }
                    }
                }.frame(maxHeight: 190)
            }.padding(.horizontal, 4)
            if !manager.allTags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TAGS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(ShelfTheme.muted)
                    FlowLayout(spacing: 5) {
                        ForEach(manager.allTags, id: \.self) { tag in
                            Button { manager.page = .spaces; manager.searchText = tag } label: {
                                Text(tag).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(ShelfTheme.accent.opacity(0.45), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 8)
            }
              }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                if manager.connections.contains(where: { $0.provider.pricing != nil }) {
                    Label("\(PricingInfo.dollars(manager.monthlyTotal)) / month est.", systemImage: "dollarsign.circle").font(.system(size: 12, weight: .semibold))
                }
                Label(manager.attentionCount == 0 ? "Everything looks fine" : "\(manager.attentionCount) need attention", systemImage: manager.attentionCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(manager.attentionCount == 0 ? ShelfTheme.muted : Color.orange)
                Label("\(manager.activeTransfers) active uploads", systemImage: "arrow.up.circle").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            Button { manager.openLoginSettings() } label: {
                Label(manager.loginStatus, systemImage: "power").font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).foregroundStyle(ShelfTheme.muted)
        }.padding(18).frame(width: 250).frame(maxHeight: .infinity).background(Color.white.opacity(0.5))
            .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.07)).frame(width: 1) }
    }
    private var accountTypes: [Provider] {
        Provider.allCases.filter { provider in manager.connections.contains { $0.provider == provider } }
    }
    private func accountCaption(_ provider: Provider) -> String {
        let spaces = manager.connections.filter { $0.provider == provider }
        var parts = ["\(spaces.count) \(spaces.count == 1 ? "space" : "spaces")"]
        let measured = spaces.compactMap { manager.usage[$0.id] }.filter { $0.isReported || $0.measured == true }
        if !measured.isEmpty { parts.append(ByteCountFormatter.string(fromByteCount: measured.reduce(0) { $0 + $1.usedBytes }, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
    private func navItem(_ title: String, symbol: String, page: DashboardPage, badge: String?) -> some View {
        let selected = manager.page == page && (page != .spaces || manager.quickFilter == .all)
        return Button { if page == .spaces { manager.showAllSpaces() } else { manager.page = page } } label: {
            HStack { Label(title, systemImage: symbol); Spacer(); if let badge { Text(badge).opacity(0.55) } }
                .font(.system(size: 13, weight: selected ? .semibold : .regular)).padding(12)
                .background(selected ? ink.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func quick(_ title: String, symbol: String, filter: QuickFilter, count: Int, tint: Color? = nil) -> some View {
        let selected = manager.page == .spaces && manager.quickFilter == filter
        return Button { manager.page = .spaces; manager.searchText = ""; manager.providerFilter = nil; manager.mountedOnly = false; manager.quickFilter = filter } label: {
            HStack { Label(title, systemImage: symbol).foregroundStyle(tint ?? ink); Spacer(); Text(String(count)).foregroundStyle(ShelfTheme.muted) }
                .font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.vertical, 6).padding(.horizontal, 8)
                .background(selected ? ink.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func nav(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 13)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
    }
    private var totalsPanel: some View {
        let totals = manager.shelfTotals
        return HStack(alignment: .top, spacing: 12) {
            metric(ByteCountFormatter.string(fromByteCount: totals.storedBytes, countStyle: .file), label: "Total stored on your shelf", symbol: "tray.full")
            if totals.quotaCapacity > 0 {
                metric(ByteCountFormatter.string(fromByteCount: totals.quotaLeft, countStyle: .file), label: "Free of \(ByteCountFormatter.string(fromByteCount: totals.quotaCapacity, countStyle: .file)) in \(totals.quotaAccounts) account\(totals.quotaAccounts == 1 ? "" : "s") with a plan", symbol: "chart.pie")
            }
            if totals.freeTierCapacity > 0 {
                metric(ByteCountFormatter.string(fromByteCount: totals.freeTierLeft, countStyle: .file), label: totals.freeTierLeft == 0 ? "Free tier used up · pay as you go" : "Free tier left of \(ByteCountFormatter.string(fromByteCount: totals.freeTierCapacity, countStyle: .file))", symbol: "gift")
            }
        }
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
    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bring your own storage.").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("1. Choose a provider, name your space, and review access and startup preferences.")
            Text("2. Sign in with Google in your browser, finish Apple sign-in in Terminal, or provide scoped object-storage credentials (S3, GCS, Azure, Cloudflare R2, Backblaze B2, IDrive e2).")
            Text("3. Object storage defaults to Archive mode: copy files in, and open them only when needed to avoid download fees. Use the Activity page to check transfers before disconnecting.")
            Text("Google accounts can reuse saved app credentials. iCloud is experimental and needs periodic reauthentication. Object-storage spaces can optionally be encrypted when you add them.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
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
                    Text(storage.provider.title + (storage.provider.platformName.map { " · " + $0 } ?? "") + (storage.encrypted ? " · 🔒 Encrypted" : "")).font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.8)).lineLimit(1)
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
            if storage.encrypted { Button("Copy encryption recovery key") { manager.copyRecoveryKey(storage) } }
            Button("View log") { manager.showLog(storage) }
            if storage.provider.prefersArchive {
                Button(storage.isArchive ? "Switch to live mode" : "Switch to archive mode") { manager.setMode(storage, storage.isArchive ? .live : .archive) }
            }
            if storage.provider.isObjectStorage {
                if storage.provider.isObjectStorage && !storage.readOnly {
                    Button("Archive folder to this space…") { manager.archiveFolder(storage) }.disabled(isBusy)
                    Button("Verify archive…") { manager.verifyArchive(storage) }.disabled(isBusy)
                }
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
                    PricingButton(storage: storage, usedBytes: value?.usedBytes)
                    Spacer(minLength: 4)
                    if let remaining = parts.remaining { Text(remaining).font(.system(size: 12, weight: .semibold)).foregroundStyle(quota.level == .warning ? Color.orange : ink) }
                }
                if quota.limit != nil { UsageBar(quota: quota) } else { Color.clear.frame(height: 6) }
                Text((parts.warning.map { $0 + (storage.provider.pricing.map { " (~" + PricingInfo.dollars($0.monthlyStorageCost(usedBytes: quota.used)) + "/mo)" } ?? "") }) ?? archiveCaption(parts.caption)).font(.system(size: 10)).foregroundStyle(parts.warning != nil ? Color.red : ShelfTheme.muted).lineLimit(2)
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
