import ChatKit
import SwiftUI

// MARK: - DiscoverSidebar
//
// The "发现" tab in WeChat is a directory of features: Moments, Scan, Search,
// Shake, Mini Programs. We repurpose it as a directory of CLAUDE tools and
// skills the user can browse / drop into a conversation.
//
// Tapping a row publishes a selection that the chat composer can read to
// pre-fill the prompt — that wiring is added in Phase C. For now it's a
// read-only browser.

public struct DiscoverSidebar: View {
    @Environment(AppViewModel.self) private var vm

    @State private var skills: [CommandInfo] = []
    @State private var loadError: String?
    @State private var isLoading = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header — matches the chats/contacts header height so all three
            // sidebars feel like the same chassis.
            HStack {
                Text("发现")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.sidebarSearch)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader(title: "技能 (Skills)", count: skills.count)

                    if skills.isEmpty && !isLoading {
                        emptyState
                    } else {
                        ForEach(skills, id: \.name) { skill in
                            DiscoverRow(command: skill)
                            Divider().padding(.leading, 56)
                        }
                    }

                    if let err = loadError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(12)
                    }
                }
            }
        }
        .background(AppColors.sidebar)
        .task {
            await reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.tertiaryText)
            Text("暂无可用技能")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppColors.secondaryText)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Use the project of the current session to scope skills correctly.
            let currentProject: String? = vm.currentSessionId.flatMap { sid in
                vm.sessions.first(where: { $0.id == sid })?.projectPath
            }
            let all = try await vm.apiClient.fetchCommands(projectPath: currentProject)
            // Filter to namespace "skill" if present; otherwise show everything
            // tagged as a slash command.
            let skillsOnly = all.filter { $0.namespace == "skill" }
            skills = skillsOnly.isEmpty ? all : skillsOnly
        } catch {
            loadError = "加载失败: \(error.localizedDescription)"
        }
    }
}

private struct DiscoverRow: View {
    let command: CommandInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.cardIconBackground)
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.sendButton)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.titleText)
                    .lineLimit(1)
                Text(command.description)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch command.namespace {
        case "skill": return "wand.and.stars"
        case "builtin": return "command.square"
        default: return "slash.circle"
        }
    }
}
