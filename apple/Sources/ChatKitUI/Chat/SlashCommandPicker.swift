import ChatKit
import SwiftUI

// MARK: - SlashCommandPicker
//
// Popover surfaced from the composer when the user types `/` at the start of
// the message. Lists built-in + project + user commands fetched from
// `/api/commands/list`. Click a row to insert it into the composer; the
// command is then sent as a regular `claude-command` over the WebSocket — the
// Claude SDK on the server interprets it as a slash command.

public struct SlashCommandPicker: View {
    let commands: [CommandInfo]
    let query: String
    let onPick: (CommandInfo) -> Void

    public init(commands: [CommandInfo], query: String, onPick: @escaping (CommandInfo) -> Void) {
        self.commands = commands
        self.query = query
        self.onPick = onPick
    }

    private var filtered: [CommandInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, q != "/" else { return commands }
        return commands.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "command")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                Text("Claude Code 命令 (\(filtered.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text("↩ 插入")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(AppColors.cardIconBackground)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(AppColors.tertiaryText)
                    Text("没有匹配的命令")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { cmd in
                            Button(action: { onPick(cmd) }) {
                                row(cmd)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 360)
    }

    private func row(_ cmd: CommandInfo) -> some View {
        HStack(spacing: 10) {
            Text(cmd.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColors.primaryText)
                .frame(minWidth: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.description.isEmpty ? cmd.name : cmd.description)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(2)
                Text(namespaceLabel(cmd.namespace))
                    .font(.system(size: 9))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(Color.clear)
    }

    private func namespaceLabel(_ ns: String) -> String {
        switch ns {
        case "builtin": return "内置"
        case "user":    return "用户 (~/.claude/commands/)"
        case "project": return "项目 (.claude/commands/)"
        case "skill":   return "Skill"
        default:        return ns
        }
    }
}
