import ChatKit
import SwiftUI

// MARK: - SettingsView

public struct SettingsView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .display

    // Add-server form state
    @State private var showAddServerForm = false
    @State private var newServerURL: String = "http://localhost:3001"
    @State private var newServerDisplayName: String = ""
    @State private var newServerURLError: String? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .display:   displaySection
                    case .behavior:  behaviorSection
                    case .servers:   serversSection
                    case .account:   accountSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 440, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab button

    private func tabButton(_ tab: SettingsTab) -> some View {
        Button(action: { selectedTab = tab }) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                Text(tab.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selectedTab == tab ? AppColors.sendButton : AppColors.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selectedTab == tab
                ? AppColors.sendButton.opacity(0.1)
                : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Display section

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "显示")

            VStack(alignment: .leading, spacing: 8) {
                Text("外观")
                    .font(.system(size: 13, weight: .medium))
                Picker("外观", selection: Bindable(settings).appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("「跟随系统」会随 macOS 的浅色/深色设置自动切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("字体大小")
                    .font(.system(size: 13, weight: .medium))
                Picker("字体大小", selection: Bindable(settings).chatFontSize) {
                    ForEach(AppFontSize.allCases, id: \.self) { size in
                        Text(size.label)
                            .font(.system(size: size.cgFloat))
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Preview
                HStack(spacing: 8) {
                    AvatarView(seed: "preview", title: "C", size: 32)
                    Text("这是字体预览文字 — Hello World")
                        .font(AppFont.message(size: settings.chatFontSize))
                        .foregroundStyle(AppColors.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - Behavior section

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "行为")

            Toggle(isOn: Bindable(settings).autoApproveAll) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动批准所有工具调用")
                        .font(.system(size: 13, weight: .medium))
                    Text("开启后 Claude 将无需确认即可读写文件和执行命令")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    // MARK: - Servers section

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "服务器")

            let profiles = vm.serverProfileStore.list()
            if profiles.isEmpty {
                Text("暂无服务器配置")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(profiles) { profile in
                    serverRow(profile)
                }
            }

            Divider()

            // Add server form toggle
            if showAddServerForm {
                addServerForm
            } else {
                Button(action: { showAddServerForm = true }) {
                    Label("添加服务器", systemImage: "plus.circle")
                        .foregroundStyle(AppColors.actionText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
            }
        }
    }

    private func serverRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if vm.currentServerProfile?.id == profile.id {
                        Text("最近使用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppColors.sendButton, in: Capsule())
                    }
                }
                Text("\(profile.url.absoluteString) · \(profile.username)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            HStack(spacing: 8) {
                if vm.currentServerProfile?.id != profile.id {
                    Button("选为当前") {
                        Task { await vm.switchProfile(profile) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.actionText)
                    .buttonStyle(.plain)
                }
                Button(role: .destructive, action: {
                    vm.serverProfileStore.remove(profile.id)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Add server form

    private var addServerForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加服务器")
                .font(.system(size: 13, weight: .semibold))

            LabeledContent("URL") {
                TextField("http://localhost:3001", text: $newServerURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if let err = newServerURLError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            LabeledContent("名称") {
                TextField("本地开发", text: $newServerDisplayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") {
                    showAddServerForm = false
                    newServerURL = "http://localhost:3001"
                    newServerDisplayName = ""
                    newServerURLError = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("添加") { addServer() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.sendButton)
                    .disabled(newServerURL.isEmpty || newServerDisplayName.isEmpty)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Account section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "账户")

            if let user = vm.currentUser {
                HStack(spacing: 10) {
                    AvatarView(seed: "user-\(user.id)", title: user.username, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.username)
                            .font(.system(size: 14, weight: .medium))
                        Text("已登录")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.sendButton)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            Button(role: .destructive, action: {
                Task {
                    await vm.logoutAndCleanup()
                    dismiss()
                }
            }) {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Add server action

    private func addServer() {
        guard let url = URL(string: newServerURL), url.scheme != nil else {
            newServerURLError = "URL 格式无效"
            return
        }
        newServerURLError = nil
        let profile = ServerProfile(
            url: url,
            displayName: newServerDisplayName.isEmpty
                ? (url.host ?? "服务器")
                : newServerDisplayName,
            username: ""
        )
        vm.serverProfileStore.upsert(profile)
        showAddServerForm = false
        newServerURL = "http://localhost:3001"
        newServerDisplayName = ""
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.secondaryText)
            .textCase(.uppercase)
    }
}

// MARK: - Settings Tab

private enum SettingsTab: String, CaseIterable, Identifiable {
    case display  = "display"
    case behavior = "behavior"
    case servers  = "servers"
    case account  = "account"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display:  return "显示"
        case .behavior: return "行为"
        case .servers:  return "服务器"
        case .account:  return "账户"
        }
    }

    var icon: String {
        switch self {
        case .display:  return "textformat"
        case .behavior: return "slider.horizontal.3"
        case .servers:  return "server.rack"
        case .account:  return "person.circle"
        }
    }
}
