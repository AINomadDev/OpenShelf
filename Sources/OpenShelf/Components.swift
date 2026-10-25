import SwiftUI

// Shared visual language for the dashboard and connection flow.
enum ShelfTheme {
    static let ink = Color(red: 0.13, green: 0.16, blue: 0.14)
    static let paper = Color(red: 0.965, green: 0.96, blue: 0.94)
    static let muted = Color(red: 0.47, green: 0.49, blue: 0.46)
    static let accent = Color(red: 0.98, green: 0.83, blue: 0.28)
    static func color(_ provider: Provider) -> Color {
        switch provider {
        case .googleDrive: return Color(red: 0.29, green: 0.48, blue: 0.34)
        case .iCloud: return Color(red: 0.28, green: 0.52, blue: 0.79)
        case .s3: return Color(red: 0.75, green: 0.42, blue: 0.15)
        case .gcs: return Color(red: 0.35, green: 0.46, blue: 0.75)
        case .azureBlob: return Color(red: 0.16, green: 0.49, blue: 0.67)
        case .s3Compatible: return Color(red: 0.55, green: 0.38, blue: 0.67)
        case .cloudflareR2: return Color(red: 0.90, green: 0.45, blue: 0.10)
        case .backblazeB2: return Color(red: 0.80, green: 0.18, blue: 0.20)
        case .idriveE2: return Color(red: 0.12, green: 0.55, blue: 0.55)
        case .wasabi: return Color(red: 0.2, green: 0.62, blue: 0.35)
        case .digitalOceanSpaces: return Color(red: 0.0, green: 0.41, blue: 1.0)
        case .other: return muted
        }
    }
}

struct ShelfButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(prominent ? Color.white : ShelfTheme.ink)
            .background(prominent ? ShelfTheme.ink : Color.white, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(prominent ? Color.clear : ShelfTheme.ink.opacity(0.1)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ProviderBadge: View {
    let provider: Provider
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: provider.symbol).font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(ShelfTheme.color(provider)).frame(width: size, height: size)
            .background(ShelfTheme.color(provider).opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct ShelfSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(ShelfTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(ShelfTheme.ink.opacity(0.07)))
    }
}

// Structured pieces of a usage line so cards can lay them out as a headline, a limit and a remainder.
struct UsageBreakdown {
    let used: String
    let limit: String?
    let remaining: String?
    let caption: String?
    let warning: String?
    static func make(_ quota: QuotaStatus, freeTier: Bool, accountName: String?) -> UsageBreakdown {
        let bytes = UsageText.bytes
        let scope = accountName.map { "Whole \($0) account" } ?? (freeTier ? "Free tier" : nil)
        guard let limit = quota.limit else { return UsageBreakdown(used: bytes(quota.used), limit: nil, remaining: nil, caption: "stored", warning: nil) }
        let warning = quota.level == .exceeded ? (freeTier ? "Free tier used up · \(bytes(quota.overage)) billed pay-as-you-go" : "Full") : nil
        return UsageBreakdown(used: bytes(quota.used), limit: "of " + bytes(limit), remaining: quota.level == .exceeded ? nil : bytes(quota.remaining ?? 0) + " left", caption: scope, warning: warning)
    }
}

enum UsageText {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    // One-line summary shared by the space card and the usage panel.
    static func unreported(_ usage: StorageUsage?) -> String {
        usage?.measured == true ? bytes(usage?.usedBytes ?? 0) + " stored · measured" : "Quota not reported"
    }
    static func summary(_ quota: QuotaStatus, freeTier: Bool, accountName: String? = nil) -> String {
        let suffix = accountName.map { " · whole \($0) account" } ?? ""
        return base(quota, freeTier: freeTier) + suffix
    }
    private static func base(_ quota: QuotaStatus, freeTier: Bool) -> String {
        guard let limit = quota.limit else { return bytes(quota.used) + " stored" }
        if quota.level == .exceeded {
            return freeTier ? "Free tier used up · \(bytes(quota.overage)) billed pay-as-you-go" : "Full · \(bytes(quota.used)) of \(bytes(limit))"
        }
        return "\(bytes(quota.used)) of \(bytes(limit))" + (freeTier ? " free" : "") + " · \(bytes(quota.remaining ?? 0)) left"
    }
}

struct UsageBar: View {
    let quota: QuotaStatus
    var tint: Color {
        switch quota.level {
        case .exceeded: return .red
        case .warning: return .orange
        default: return .green
        }
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ShelfTheme.ink.opacity(0.08))
                Capsule().fill(tint).frame(width: proxy.size.width * (quota.fraction ?? 0))
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}


final class PopoverFlag: ObservableObject { @Published var shown = false }

// Click-to-open pricing card. Uses a popover (not .help) so it can hold structured rows and a link.
struct PricingButton: View {
    let storage: Storage
    let usedBytes: Int64?
    @StateObject private var flag = PopoverFlag()
    var body: some View {
        if let pricing = storage.provider.pricing {
            Button { flag.shown.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(ShelfTheme.muted)
            }.buttonStyle(.plain).help("Pay-as-you-go pricing for \(storage.provider.title)")
                .popover(isPresented: $flag.shown, arrowEdge: .bottom) { PricingCard(provider: storage.provider, pricing: pricing, usedBytes: usedBytes) }
        }
    }
}

struct PricingCard: View {
    let provider: Provider
    let pricing: PricingInfo
    let usedBytes: Int64?
    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(ShelfTheme.color(provider)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(ShelfTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProviderBadge(provider: provider, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Pay-as-you-go pricing (estimate)").font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                }
            }
            Divider()
            if let free = pricing.freeBytes {
                row("gift", "Free tier", "\(UsageText.bytes(free)) of storage free each month. After that you pay as you go.")
            }
            row("internaldrive", "Storage", String(format: "$%.4f per GB-month (about $%.2f per TB)", pricing.storagePerGB, pricing.storagePerGB * 1000))
            row("arrow.down.circle", "Egress (downloads)", pricing.egress)
            row("arrow.left.arrow.right", "Requests", pricing.operations)
            if let extra = pricing.extra { row("sparkles", "Good to know", extra) }
            if let used = usedBytes {
                Divider()
                let cost = pricing.monthlyStorageCost(usedBytes: used)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your estimated storage bill").font(.system(size: 11, weight: .semibold))
                        Text(UsageText.bytes(used) + " stored" + (pricing.freeBytes.map { used > $0 ? " · free tier exhausted" : " · within free tier" } ?? "")).font(.system(size: 10)).foregroundStyle(ShelfTheme.muted)
                    }
                    Spacer()
                    Text(cost == 0 ? "$0.00" : PricingInfo.dollars(cost) + "/mo").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(cost == 0 ? Color.green : ShelfTheme.ink)
                }
            }
            HStack {
                Link("Open \(provider.title) pricing", destination: pricing.url).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("List prices, " + PricingInfo.asOf + ". Region and tier vary.").font(.system(size: 9)).foregroundStyle(ShelfTheme.muted)
            }
        }.padding(16).frame(width: 340).background(Color.white).foregroundStyle(ShelfTheme.ink)
    }
}
