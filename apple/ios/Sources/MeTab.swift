import SwiftUI
import ChatKit

// MARK: - MeTab ("我")
//
// Profile card + grouped settings rows, mirroring the web WeChatMeTab and the
// macOS MeSidebar. Rows are mostly informational placeholders for now (the heavy
// editors land as /api/auth/* gets wired); the structure matches WeChat so the
// surface feels complete.

struct MeTab: View {
    @Environment(IOSAppModel.self) private var model
    @State private var openSection: String?
    @State private var confirmingSignOut = false
    @State private var usage: ClaudeUsageLimits?
    @State private var usageLoaded = false

    private var displayName: String { model.myDisplayName }

    var body: some View {
        NavigationStack {
            List {
                Section { profileCard }

                Section {
                    settingsRow("account", icon: "checkmark.shield", title: "账号信息",
                                subtitle: model.currentUser?.username ?? "未登录 (dev-bypass)")
                    settingsRow("notifications", icon: "bell", title: "新消息通知")
                }

                usageSection

                Section {
                    Toggle(isOn: Binding(
                        get: { model.requireToolApproval },
                        set: { model.requireToolApproval = $0 })
                    ) {
                        Label("工具执行前确认", systemImage: "lock.shield")
                    }
                    .tint(WC.accent)
                } footer: {
                    Text("开启后,Claude 执行工具(改文件、跑命令等)前会先征求你同意;10 分钟未回应则自动执行,不会卡住。关闭(默认)则全部自动执行。")
                }

                Section {
                    settingsRow("appearance", icon: "moon", title: "通用 / 外观")
                    settingsRow("server", icon: "server.rack", title: "服务器配置",
                                subtitle: model.serverURLString)
                    settingsRow("blacklist", icon: "nosign", title: "黑名单",
                                subtitle: model.blacklistedPaths.isEmpty ? "无" : "\(model.blacklistedPaths.count) 个路径")
                }

                if openSection == "blacklist" {
                    Section("黑名单路径（这些路径下的会话不显示）") {
                        if model.blacklistedPaths.isEmpty {
                            Text("暂无。在通讯录里左滑联系人选「拉黑」即可添加。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.blacklistedPaths).sorted(), id: \.self) { path in
                                HStack {
                                    Text(path).font(.system(size: 12)).lineLimit(2)
                                    Spacer()
                                    Button("解除") { model.setBlacklisted(path, false) }
                                        .font(.system(size: 12)).foregroundStyle(WC.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    settingsRow("about", icon: "info.circle", title: "关于 Claude Chat")
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }

                if let s = openSection, s != "logout", s != "blacklist" {
                    Section { detailCard(s) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我")
            .task {
                // Best-effort, lightweight: refresh on appear, no polling.
                await model.pingNow() // probe latency now (heartbeat is every 25s)
                usage = await model.loadUsageLimits()
                usageLoaded = true
            }
            .refreshable {
                // Pull-to-refresh forces a manual usage refresh; the server still
                // floors actual upstream calls at 5 minutes.
                usage = await model.loadUsageLimits(force: true)
                usageLoaded = true
            }
            .confirmationDialog("退出登录?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { Task { await model.signOut() } }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            IOSAvatar(seed: model.myAvatarSeed, title: displayName, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 18, weight: .semibold))
                connectionIndicator
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    /// 3-state connection health row driven by `model.connectionState`.
    @ViewBuilder
    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            switch model.connectionState {
            case .online:
                Image(systemName: "wifi")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("已连接服务端")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                latencyBadge
            case .reconnecting(let n):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("重连中" + (n > 0 ? " · 第 \(n) 次" : "…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                Text("已离线 · 网络不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text("连接失败 · 点击重连")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .failed = model.connectionState {
                Task { await model.reconnect() }
            }
        }
    }

    /// Tappable round-trip latency pill (ping→pong). Tap to re-measure.
    private var latencyBadge: some View {
        Button {
            Task { await model.pingNow() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10))
                Text(Self.latencyLabel(model.latencyMs))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(Self.latencyColor(model.latencyMs))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.gray.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private static func latencyLabel(_ ms: Int?) -> String {
        guard let ms else { return "测速中…" }
        return "\(ms) ms"
    }

    private static func latencyColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        if ms < 100 { return .green }
        if ms < 300 { return .orange }
        return .red
    }

    @ViewBuilder
    private func settingsRow(_ section: String, icon: String, title: String, subtitle: String? = nil) -> some View {
        Button {
            withAnimation { openSection = (openSection == section) ? nil : section }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Usage card (用量)

    private var usageSection: some View {
        Section {
            usageRow(icon: "clock", title: "5 小时", window: usage?.fiveHour)
            usageRow(icon: "calendar", title: "7 天", window: usage?.sevenDay)
        } header: {
            HStack {
                Text("用量")
                Spacer()
                if let asOf = Self.asOfLabel(usage?.asOf) {
                    Text("更新于 \(asOf)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        } footer: {
            Text("Claude 使用额度的实时占用,达到上限后将在重置时间后恢复。下拉刷新(最低间隔 5 分钟)。")
        }
    }

    @ViewBuilder
    private func usageRow(icon: String, title: String, window: UsageWindow?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    if let window {
                        Text("\(Int(window.utilizationPct.rounded()))%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(usageColor(window.utilizationPct))
                    } else {
                        Text(usageLoaded ? "暂无数据" : "加载中…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if let window {
                    ProgressView(value: min(max(window.utilizationPct, 0), 100), total: 100)
                        .tint(usageColor(window.utilizationPct))
                    Text("重置于 \(Self.resetLabel(window.resetsAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func usageColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    /// Parse an RFC3339 `resetsAt` into a friendly local label. The 5h window
    /// resets the same day (time alone is enough), but the 7d window resets days
    /// out — "00:00" by itself is meaningless, so prepend the date unless it's
    /// today.
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
    static func resetLabel(_ rfc3339: String) -> String {
        let date = rfc3339Full.date(from: rfc3339) ?? rfc3339Basic.date(from: rfc3339)
        guard let date else { return rfc3339 }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return resetTimeFormatter.string(from: date) }
        if cal.isDateInTomorrow(date) { return "明天 " + resetTimeFormatter.string(from: date) }
        return resetDateTimeFormatter.string(from: date)
    }

    /// `asOf` (ms epoch) → local `HH:mm` "last updated" label.
    static func asOfLabel(_ asOf: Double?) -> String? {
        guard let asOf else { return nil }
        return resetTimeFormatter.string(from: Date(timeIntervalSince1970: asOf / 1000))
    }

    @ViewBuilder
    private func detailCard(_ section: String) -> some View {
        let body: String = {
            switch section {
            case "account":
                return "当前登录账号: \(model.currentUser?.username ?? "dev-bypass")。TOTP / 密码修改 / 设备管理在后续接入 /api/auth/* 后开放。"
            case "notifications":
                return "iOS 使用系统通知中心。可在「设置 > 通知」里关闭。会话级免打扰跟服务端 isMuted 字段联动。"
            case "appearance":
                return "主题色为微信绿 (#07C160)，深色模式跟随系统。头像 hash 调色板与 macOS / Web 版一致。"
            case "server":
                return "当前服务器: \(model.serverURLString)。开发模式启用 DEV_AUTH_BYPASS=1 可免登录；生产请关闭并用 TOTP 双因素登录。"
            case "about":
                return "Claude Code CLI 客户端 · 仿微信交互 · 后端基于 claudecodeui-local fork。iOS 端 SwiftUI，与 macOS 共享 ChatKit 核心。"
            default:
                return ""
            }
        }()
        Text(body)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }
}
