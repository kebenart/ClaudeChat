import ChatKit
import SwiftUI

// MARK: - MainWindowView

/// Three-column WeChat-for-Mac layout: Rail + Sidebar + Chat
public struct MainWindowView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(\.chatFontSize) private var fontSize

    @State private var railTab: RailTab = .chats

    // ViewModels (these are stateful — keep as @State)
    @State private var listVM: SessionListViewModel
    @State private var imChatVM = ImChatViewModel()

    public init(storage: some StorageProtocol,
                apiClient: (any APIClientProtocol)? = nil) {
        _listVM = State(initialValue: SessionListViewModel(storage: storage))
    }

    /// The selected IM conversation (Stage 3 chat reads this).
    private var currentImConversation: ImConversationDTO? {
        guard let id = vm.currentSessionId else { return nil }
        return vm.imController?.conversations.first { $0.id == id }
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Column 1: Rail
            RailView(selection: $railTab)

            Divider()

            // Column 2: Sidebar
            SidebarView(tab: railTab, listVM: listVM)
                .frame(width: 280)

            Divider()

            // Column 3: Right-side detail pane. Content depends on the active
            // rail tab — chat for chats/contacts, settings detail for me,
            // welcome card for discover.
            detailPane
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: rotatedRecoveryBinding) {
            RotatedRecoveryCodeSheet(code: vm.pendingRotatedRecoveryCode ?? "") {
                vm.pendingRotatedRecoveryCode = nil
            }
        }
        .environment(\.chatFontSize, settings.chatFontSize)
        .task {
            // Initial session load (provider — still drives contacts + live dots).
            await vm.loadSessions()
            await listVM.refresh(conversations: vm.imController?.conversations ?? [],
                                 unreadCounts: vm.mergedUnreadCounts,
                                 blacklistedPaths: vm.blacklistedPaths,
                                 liveSessionIds: vm.liveSessionIds)
            await listVM.refreshAll(conversations: vm.imController?.conversations ?? [], liveSessionIds: vm.liveSessionIds)
        }
        // Re-refresh sidebar rows whenever sessions (live dots) or unread change.
        // The IM list itself re-derives via SidebarView's .task keyed on syncRevision.
        .onChange(of: vm.sessions) { _, _ in
            Task {
                await listVM.refresh(conversations: vm.imController?.conversations ?? [],
                                     unreadCounts: vm.mergedUnreadCounts,
                                     blacklistedPaths: vm.blacklistedPaths,
                                     liveSessionIds: vm.liveSessionIds)
                await listVM.refreshAll(conversations: vm.imController?.conversations ?? [], liveSessionIds: vm.liveSessionIds)
            }
        }
        .onChange(of: vm.unreadCounts) { _, _ in
            Task {
                await listVM.refresh(conversations: vm.imController?.conversations ?? [],
                                     unreadCounts: vm.mergedUnreadCounts,
                                     blacklistedPaths: vm.blacklistedPaths,
                                     liveSessionIds: vm.liveSessionIds)
            }
        }
        // Failure toast (a /state mutation didn't reach the server).
        .overlay(alignment: .top) {
            if let toast = vm.toast {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(toast.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.82), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding(.top, 14)
                .id(toast.id)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    if vm.toast?.id == toast.id { vm.toast = nil }
                }
            }
        }
        // Transient connection banner (drop/restore edge).
        .overlay(alignment: .top) {
            if let banner = vm.connectionBanner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.toast)
        .animation(.default, value: vm.connectionBanner)
    }

    private var rotatedRecoveryBinding: Binding<Bool> {
        Binding(
            get: { vm.pendingRotatedRecoveryCode != nil },
            set: { if !$0 { vm.pendingRotatedRecoveryCode = nil } }
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        switch railTab {
        case .chats, .contacts:
            if let conv = currentImConversation {
                ImChatView(conversation: conv, chatVM: imChatVM)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40)).foregroundStyle(AppColors.tertiaryText)
                    Text("选择一个会话开始").font(.system(size: 14)).foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.background)
            }
        case .discover:
            DiscoverWelcomePane()
        case .me:
            MeDetailPane(role: vm.selectedMeRole)
                .environment(settings)
        }
    }
}

// MARK: - Discover right-side welcome

private struct DiscoverWelcomePane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.tertiaryText)
            Text("发现")
                .font(.system(size: 20, weight: .semibold))
            Text("从左侧选择一个技能或命令查看详情")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.sidebar.opacity(0.4))
    }
}

// MARK: - Me right-side detail pane

private struct MeDetailPane: View {
    @Environment(AppSettings.self) private var settings
    let role: MeRole?

    var body: some View {
        Group {
            switch role {
            case .none:
                landingCard
            case .accountInfo:
                MePlaceholderCard(title: "账号信息",
                                  systemImage: "person.circle",
                                  bodyText:"在 DEV_AUTH_BYPASS 模式下登录,暂未实现修改密码/重设 TOTP。后续接入 /api/auth/* 即可。")
            case .notifications:
                MePlaceholderCard(title: "新消息通知",
                                  systemImage: "bell",
                                  bodyText:"系统通知/红点已生效。下一阶段会加按会话静音和勿扰时段。")
            case .general, .appearance:
                // The existing SettingsView lives here so we don't fragment
                // the typography / chat-font preferences.
                SettingsView()
            case .about:
                AboutCard()
            case .logout:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landingCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.tertiaryText)
            Text("我")
                .font(.system(size: 20, weight: .semibold))
            Text("从左侧选择一项设置")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.sidebar.opacity(0.4))
    }
}

private struct MePlaceholderCard: View {
    let title: String
    let systemImage: String
    let bodyText: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(AppColors.sendButton)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(bodyText)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AboutCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.sendButton)
            Text("Claude Chat")
                .font(.system(size: 20, weight: .semibold))
            Text("本地 AI 会话客户端 · 仿微信交互")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)
            Text("ClaudeChat")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Modal shown when the server has rotated the user's TOTP recovery code.
/// The user MUST copy / save the new code before dismissing — the old one is
/// now invalid and the server will not show this code again.
private struct RotatedRecoveryCodeSheet: View {
    let code: String
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("新的 TOTP 恢复码")
                .font(.system(size: 18, weight: .semibold))

            Text("你刚才使用恢复码登录,旧恢复码已失效。请立即保存下面的新恢复码,服务器不会再展示。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(code)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button(action: copy) {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .frame(width: 88)
                }
                .buttonStyle(.bordered)

                Button("我已保存,关闭", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }
}
