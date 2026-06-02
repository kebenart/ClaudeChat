import ChatKit
import SwiftUI

// MARK: - MeSidebar
//
// The "我" tab in WeChat: top profile card, then grouped settings rows.
// Tapping a row updates the right-pane selection via a small enum so the
// MainWindowView shows the corresponding detail editor instead of the chat.
//
// We don't ship every WeChat settings row — just the ones that map to
// existing capabilities: account, appearance, notifications, about. Anything
// else can come later.

public struct MeSidebar: View {
    @Environment(AppViewModel.self) private var vm
    let listVM: SessionListViewModel

    @State private var usage: ClaudeUsageLimits?
    @State private var usageLoaded = false
    @State private var refreshingUsage = false

    public init(listVM: SessionListViewModel) {
        self.listVM = listVM
    }

    public var body: some View {
        VStack(spacing: 0) {

            // Profile card
            profileCard
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            // Settings list
            ScrollView {
                VStack(spacing: 0) {
                    sectionSpacer
                    usageSection

                    sectionSpacer

                    settingsGroup(rows: [
                        MeRow(icon: "person.circle", title: "账号信息", systemRole: .accountInfo),
                        MeRow(icon: "bell", title: "新消息通知", systemRole: .notifications),
                    ])

                    sectionSpacer

                    settingsGroup(rows: [
                        MeRow(icon: "paintbrush", title: "通用", systemRole: .general),
                        MeRow(icon: "textformat.size", title: "字体与外观", systemRole: .appearance),
                    ])

                    sectionSpacer

                    settingsGroup(rows: [
                        MeRow(icon: "info.circle", title: "关于", systemRole: .about),
                        MeRow(icon: "rectangle.portrait.and.arrow.right",
                              title: "退出登录", systemRole: .logout, isDestructive: true),
                    ])

                    sectionSpacer
                    blacklistSection

                    Spacer(minLength: 32)
                }
            }
        }
        .background(AppColors.sidebar)
        .task {
            // Probe latency on appear — the background heartbeat is every 25s,
            // too slow for an at-a-glance reading when opening 我.
            await vm.pingNow()
            usage = await vm.loadUsageLimits()
            usageLoaded = true
        }
    }

    // MARK: - Usage (用量)

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("用量")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                if let asOf = Self.asOfLabel(usage?.asOf) {
                    Text("更新于 \(asOf)")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.secondaryText)
                }
                Button {
                    Task {
                        guard !refreshingUsage else { return }
                        refreshingUsage = true
                        usage = await vm.loadUsageLimits(force: true)
                        usageLoaded = true
                        refreshingUsage = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(refreshingUsage ? 360 : 0))
                        .animation(refreshingUsage
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default, value: refreshingUsage)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.secondaryText)
                .disabled(refreshingUsage)
                .help("刷新(最低间隔 5 分钟)")
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
            VStack(spacing: 0) {
                usageRow(icon: "clock", title: "5 小时", window: usage?.fiveHour)
                Divider().padding(.leading, 44)
                usageRow(icon: "calendar", title: "7 天", window: usage?.sevenDay)
            }
            .background(AppColors.sidebarSearch.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppColors.border, lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func usageRow(icon: String, title: String, window: UsageWindow?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.sendButton)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.titleText)
                    Spacer()
                    if let window {
                        Text("\(Int(window.utilizationPct.rounded()))%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Self.usageColor(window.utilizationPct))
                    } else {
                        Text(usageLoaded ? "暂无数据" : "加载中…")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.tertiaryText)
                    }
                }
                if let window {
                    usageBar(window.utilizationPct)
                    Text("重置于 \(Self.resetLabel(window.resetsAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// A load-colored utilization bar (green <70 / orange <90 / red ≥90).
    private func usageBar(_ pct: Double) -> some View {
        let frac = min(max(pct, 0), 100) / 100
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColors.border.opacity(0.6))
                Capsule().fill(Self.usageColor(pct))
                    .frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 4)
    }

    private static func usageColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    /// Parse an RFC3339 `resetsAt` into a friendly local label. The 5h window
    /// resets the same day (time alone is enough), but the 7d window resets days
    /// out — "00:00" by itself is meaningless, so prepend the date unless today.
    private static let rfc3339Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let rfc3339Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let resetTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let resetDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
    private static func resetLabel(_ rfc3339: String) -> String {
        let date = rfc3339Full.date(from: rfc3339) ?? rfc3339Basic.date(from: rfc3339)
        guard let date else { return rfc3339 }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return resetTimeFormatter.string(from: date) }
        if cal.isDateInTomorrow(date) { return "明天 " + resetTimeFormatter.string(from: date) }
        return resetDateTimeFormatter.string(from: date)
    }

    /// `asOf` (ms epoch) → local `HH:mm` "last updated" label.
    private static func asOfLabel(_ asOf: Double?) -> String? {
        guard let asOf else { return nil }
        return resetTimeFormatter.string(from: Date(timeIntervalSince1970: asOf / 1000))
    }

    private var blacklistSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("黑名单路径").font(.system(size: 11)).foregroundStyle(AppColors.secondaryText)
                Text("\(vm.blacklistedPaths.count)").font(.system(size: 10)).foregroundStyle(AppColors.tertiaryText)
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
            VStack(spacing: 0) {
                if vm.blacklistedPaths.isEmpty {
                    Text("暂无。在会话/联系人右键「拉黑此项目路径」即可添加，拉黑后其下所有会话不再显示。")
                        .font(.system(size: 11)).foregroundStyle(AppColors.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(Array(vm.blacklistedPaths).sorted(), id: \.self) { path in
                        HStack {
                            Text(path).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppColors.titleText).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("解除") { Task { await vm.setBlacklisted(path, false) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(AppColors.sendButton)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
        }
    }

    private var profileCard: some View {
        let user = vm.currentUser
        let name = vm.myDisplayName
        return HStack(spacing: 12) {
            AvatarView(seed: vm.myAvatarSeed, title: name, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.titleText)
                Text(user?.totpEnabled == true ? "TOTP 已启用" : "本地登录")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                connectionIndicator
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.tertiaryText)
        }
    }

    /// 3-state connection health row driven by `vm.connectionState`.
    @ViewBuilder
    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            switch vm.connectionState {
            case .online:
                Image(systemName: "wifi")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("已连接服务端")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                latencyBadge
            case .reconnecting(let n):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("重连中" + (n > 0 ? " · 第 \(n) 次" : "…"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                Text("已离线 · 网络不可用")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text("连接失败 · 点击重连")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .failed = vm.connectionState {
                Task { await vm.manualReconnect() }
            }
        }
    }

    /// Tappable round-trip latency pill (ping→pong). Tap to re-measure.
    private var latencyBadge: some View {
        Button {
            Task { await vm.pingNow() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                Text(Self.latencyLabel(vm.latencyMs))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(Self.latencyColor(vm.latencyMs))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.gray.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("点击重新测速")
    }

    private static func latencyLabel(_ ms: Int?) -> String {
        guard let ms else { return "测速中…" }
        return "\(ms) ms"
    }

    private static func latencyColor(_ ms: Int?) -> Color {
        guard let ms else { return AppColors.secondaryText }
        if ms < 100 { return .green }
        if ms < 300 { return .orange }
        return .red
    }

    private func settingsGroup(rows: [MeRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                meRowView(rows[i])
                if i != rows.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
        .background(AppColors.sidebarSearch.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppColors.border, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    private func meRowView(_ row: MeRow) -> some View {
        Button(action: { handle(row) }) {
            HStack(spacing: 12) {
                Image(systemName: row.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(row.isDestructive ? .red : AppColors.sendButton)
                    .frame(width: 20)
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(row.isDestructive ? .red : AppColors.titleText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionSpacer: some View {
        Color.clear.frame(height: 16)
    }

    private func handle(_ row: MeRow) {
        switch row.systemRole {
        case .logout:
            Task { await vm.logout() }
        default:
            vm.selectedMeRole = row.systemRole
        }
    }
}

// MARK: - Row model + roles

struct MeRow {
    let icon: String
    let title: String
    let systemRole: MeRole
    var isDestructive: Bool = false
}

public enum MeRole: String, Sendable {
    case accountInfo
    case notifications
    case general
    case appearance
    case about
    case logout
}
