import SwiftUI
import AppKit

private func pageHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.8)
        Text(subtitle).font(.system(size: 13)).foregroundStyle(ShelfTheme.muted)
    }.frame(maxWidth: .infinity, alignment: .leading)
}

private func stat(_ value: String, _ label: String, symbol: String, tint: Color? = nil) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint ?? ShelfTheme.muted).frame(width: 34)
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.5)
            Text(label).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
        }
        Spacer(minLength: 0)
    }.padding(15).frame(maxWidth: .infinity).background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 15))
}

private let eventTime: DateFormatter = {
    let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
}()

struct ActivityPage: View {
    @ObservedObject var manager: DriveManager

    var body: some View {
        let stats = manager.activity.values
        let uploading = stats.reduce(0) { $0 + $1.diskCache.uploadsInProgress }
        let queued = stats.reduce(0) { $0 + $1.diskCache.uploadsQueued }
        let errors = stats.reduce(0) { $0 + $1.diskCache.erroredFiles }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Activity", "Transfers, cache and a history of what OpenShelf has done.")
                HStack(spacing: 12) {
                    stat("\(uploading)", "Uploading now", symbol: "arrow.up.circle", tint: uploading > 0 ? .blue : nil)
                    stat("\(queued)", "Queued", symbol: "tray.full")
                    stat("\(errors)", "Upload errors", symbol: "exclamationmark.octagon", tint: errors > 0 ? .red : nil)
                    stat(ByteCountFormatter.string(fromByteCount: stats.reduce(0) { $0 + $1.diskCache.bytesUsed }, countStyle: .file), "Cached locally", symbol: "internaldrive")
                }
                if !manager.busy.isEmpty {
                    ShelfSection(title: "Running tasks", subtitle: "Archive, verify, clean or measure jobs started from this app. Keep the app open until they finish.") {
                        ForEach(Array(manager.busy), id: \.id) { storage in
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(storage.title).font(.system(size: 12, weight: .medium)); Spacer() }
                        }
                    }
                }
                ShelfSection(title: "Spaces", subtitle: "Live state of every connection. Uploads continue in the background even if you quit the app.") {
                    VStack(spacing: 0) {
                        ForEach(manager.connections) { storage in
                            spaceRow(storage)
                            if storage != manager.connections.last { Divider() }
                        }
                        if manager.connections.isEmpty { Text("No spaces yet.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted) }
                    }
                }
                ShelfSection(title: "History", subtitle: "Messages from recent actions, newest first. Kept on this Mac only.") {
                    if manager.events.isEmpty {
                        Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(manager.events.prefix(40)) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: symbol(event.level)).foregroundStyle(tint(event.level)).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                        Text(eventTime.string(from: event.date)).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                                    }
                                }
                            }
                            Button("Clear history") { manager.clearEvents() }.buttonStyle(ShelfButtonStyle())
                        }
                    }
                }
                Text("Live status only. A mounted drive does not establish that every file is synced.").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }.padding(28)
        }
    }

    private func symbol(_ level: EventLevel) -> String {
        switch level { case .error: return "xmark.octagon.fill"; case .warning: return "exclamationmark.triangle.fill"; case .info: return "info.circle.fill" }
    }
    private func tint(_ level: EventLevel) -> Color {
        switch level { case .error: return .red; case .warning: return .orange; case .info: return ShelfTheme.muted }
    }

    private func spaceRow(_ storage: Storage) -> some View {
        let mounted = manager.mounted.contains(storage)
        let stats = manager.activity[storage]
        let reasons = manager.attention(storage)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderBadge(provider: storage.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(storage.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([storage.provider.title, storage.provider.platformName, storage.isArchive ? "Archive" : "Live", storage.readOnly ? "Read-only" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(ShelfTheme.muted).lineLimit(1)
                }
                Spacer()
                Label(mounted ? "Mounted" : manager.isRunning(storage) ? "Starting" : "Not mounted", systemImage: "circle.fill")
                    .font(.system(size: 11)).foregroundStyle(mounted ? Color.green : ShelfTheme.muted)
                Button("Log") { manager.showLog(storage) }.buttonStyle(ShelfButtonStyle())
                if mounted { Button("Open") { manager.open(storage) }.buttonStyle(ShelfButtonStyle()) }
            }
            if let stats {
                HStack(spacing: 16) {
                    Label("\(stats.diskCache.uploadsInProgress) uploading", systemImage: "arrow.up.circle")
                    Label("\(stats.diskCache.uploadsQueued) queued", systemImage: "tray")
                    Label("\(stats.diskCache.erroredFiles) errors", systemImage: "exclamationmark.octagon").foregroundStyle(stats.diskCache.erroredFiles > 0 ? Color.red : ShelfTheme.muted)
                    Label("\(stats.inUse) open", systemImage: "doc")
                    Label(ByteCountFormatter.string(fromByteCount: stats.diskCache.bytesUsed, countStyle: .file) + " cached", systemImage: "internaldrive")
                    Spacer()
                }.font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            } else {
                Text(manager.statuses[storage] ?? (mounted ? "Waiting for transfer status…" : "Not mounted")).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }
            ForEach(reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.orange)
            }
        }.padding(.vertical, 10)
    }
}

struct CostsPage: View {
    @ObservedObject var manager: DriveManager

    var body: some View {
        let priced = manager.connections.filter { $0.provider.pricing != nil }
        let stored = manager.connections.reduce(Int64(0)) { $0 + (manager.usage[$1.id].flatMap { $0.accountWide == true ? nil : $0.usedBytes } ?? 0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Costs & budgets", "Estimated pay-as-you-go storage cost from list prices. Excludes requests and egress.")
                HStack(spacing: 12) {
                    stat(PricingInfo.dollars(manager.monthlyTotal), "Estimated per month", symbol: "dollarsign.circle")
                    stat(ByteCountFormatter.string(fromByteCount: stored, countStyle: .file), "Stored across spaces", symbol: "externaldrive")
                    stat("\(manager.budgets.count)", "Budgets set", symbol: "bell.badge")
                }
                if priced.isEmpty {
                    ShelfSection(title: "No priced storage yet", subtitle: "Add an object-storage space (R2, B2, e2, S3, GCS, Azure, Wasabi, Spaces) to see costs here.") { EmptyView() }
                }
                ForEach(priced) { storage in row(storage) }
                Text("Free tiers are applied per space, which can overstate the total if several spaces share one provider account. Prices are approximate US list prices; check each provider before relying on them.")
                    .font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            }.padding(28)
        }
    }

    private func row(_ storage: Storage) -> some View {
        let value = manager.usage[storage.id]
        let cost = manager.monthlyCost(storage)
        let samples = manager.history[storage.id] ?? []
        let growth = UsageHistory.growthPerDay(samples)
        return ShelfSection(title: storage.title, subtitle: [storage.provider.title, storage.provider.platformName].compactMap { $0 }.joined(separator: " · ")) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.map { ByteCountFormatter.string(fromByteCount: $0.usedBytes, countStyle: .file) } ?? "Not measured").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("stored").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(cost.map { PricingInfo.dollars($0) + " / mo" } ?? "—").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("estimated storage").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                }
                if let restore = manager.restoreCost(storage) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PricingInfo.dollars(restore)).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("to download everything").font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
                    }
                }
                Spacer()
                if samples.count > 1 { Sparkline(values: samples.map { Double($0.bytes) }).frame(width: 140, height: 44) }
            }
            if let quota = storage.quota(for: value), quota.limit != nil { UsageBar(quota: quota) }
            HStack(spacing: 18) {
                if let growth, growth != 0 {
                    Label("\(growth > 0 ? "+" : "−")\(ByteCountFormatter.string(fromByteCount: Int64(abs(growth)), countStyle: .file)) per day", systemImage: "chart.line.uptrend.xyaxis")
                }
                if let days = manager.daysUntilFreeTier(storage) {
                    Label(days == 0 ? "Free tier used up" : "Free tier ends in ~\(days) days", systemImage: "hourglass")
                }
                if let pricing = storage.provider.pricing { Label("\(PricingInfo.dollars(pricing.storagePerGB))/GB-month list", systemImage: "tag") }
                Spacer()
                BudgetEditor(manager: manager, storage: storage)
            }.font(.system(size: 11)).foregroundStyle(ShelfTheme.muted)
            switch manager.budgetLevel(storage) {
            case .exceeded: Label("Over the \(PricingInfo.dollars(manager.budgets[storage.id] ?? 0)) monthly budget", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.red)
            case .nearing: Label("Near the \(PricingInfo.dollars(manager.budgets[storage.id] ?? 0)) monthly budget", systemImage: "bell.badge").font(.system(size: 11)).foregroundStyle(Color.orange)
            default: EmptyView()
            }
        }
    }
}

struct BudgetEditor: View {
    @ObservedObject var manager: DriveManager
    let storage: Storage
    @StateObject private var draft = BudgetDraft()
    var body: some View {
        HStack(spacing: 6) {
            Text("Budget $")
            TextField("none", text: $draft.text).textFieldStyle(.roundedBorder).frame(width: 60)
                .onSubmit { manager.setBudget(Double(draft.text.trimmingCharacters(in: .whitespaces)), for: storage) }
        }.onAppear { draft.text = manager.budgets[storage.id].map { String($0) } ?? "" }
    }
}

@MainActor final class BudgetDraft: ObservableObject { @Published var text = "" }

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { proxy in
            let low = values.min() ?? 0, high = max(values.max() ?? 1, low + 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = proxy.size.height * (1 - CGFloat((value - low) / (high - low)))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }.stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
