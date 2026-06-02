import SwiftUI
import ChatKit
import UIKit

// MARK: - DiscoverTab ("发现")
//
// A Claude Code-flavored "discover" surface: a directory of slash commands and
// skills the server exposes. Mirrors the web WeChatDiscoverTab. Tapping a row
// copies the command name to the clipboard (so it can be pasted into any chat
// composer) and shows a brief confirmation. This is NOT WeChat Moments — it's a
// capability directory.

struct DiscoverTab: View {
    @Environment(IOSAppModel.self) private var model

    @State private var commands: [CommandInfo] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var selectedKind: Kind = .skill
    @State private var copiedName: String?

    private enum Kind: String, CaseIterable { case skill = "技能", command = "命令" }

    /// Skills are surfaced by the server with a "skill" namespace; everything
    /// else is a slash command (builtin / user / project).
    private var skills: [CommandInfo] { commands.filter { $0.namespace == "skill" } }
    private var slashCommands: [CommandInfo] { commands.filter { $0.namespace != "skill" } }

    private var visible: [CommandInfo] {
        let base = selectedKind == .skill ? skills : slashCommands
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedKind) {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        Text("\(kind.rawValue) (\(kind == .skill ? skills.count : slashCommands.count))")
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if isLoading {
                    Spacer(); ProgressView("加载中…"); Spacer()
                } else if visible.isEmpty {
                    ContentUnavailableView("无匹配结果", systemImage: "sparkles")
                } else {
                    List(visible) { cmd in
                        Button { copy(cmd) } label: { row(cmd) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("发现")
            .searchable(text: $search, prompt: "搜索技能或命令")
            .overlay(alignment: .bottom) {
                if let name = copiedName {
                    Text("已复制 \(name) 到剪贴板")
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
            .task {
                commands = await model.availableCommands()
                isLoading = false
            }
        }
    }

    @ViewBuilder private func row(_ cmd: CommandInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: cmd.namespace == "skill" ? "sparkles" : "terminal")
                .font(.system(size: 15))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                if !cmd.description.isEmpty {
                    Text(cmd.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func copy(_ cmd: CommandInfo) {
        UIPasteboard.general.string = cmd.name
        withAnimation { copiedName = cmd.name }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if copiedName == cmd.name { copiedName = nil } }
        }
    }
}
