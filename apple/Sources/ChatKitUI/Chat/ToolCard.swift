import ChatKit
import SwiftUI

// MARK: - ToolCard

/// Displays a tool invocation as a WeChat-style card.
/// Shows pending approval state with countdown + approve/reject buttons,
/// or executed/rejected state when done.
public struct ToolCard: View {
    let message: ChatMessage
    let onApprove: (() -> Void)?
    let onReject: (() -> Void)?

    @State private var secondsRemaining: Int = 30
    @State private var timerTask: Task<Void, Never>?

    public init(message: ChatMessage,
                onApprove: (() -> Void)? = nil,
                onReject: (() -> Void)? = nil) {
        self.message = message
        self.onApprove = onApprove
        self.onReject = onReject
    }

    private var tool: ToolInvocation? { message.toolUse }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Tool icon
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.cardIconBackground)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName(for: tool?.name ?? ""))
                        .font(.system(size: 18))
                        .foregroundStyle(iconColor(for: tool?.name ?? ""))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool?.name ?? "Tool")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.primaryText)

                    // Input summary
                    if let input = tool?.input, !input.isEmpty {
                        Text(inputSummary(input))
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(AppColors.cardDivider)

            // Footer: state
            toolFooter
        }
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppColors.lightBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
        .frame(maxWidth: 360, alignment: .leading)
        .onAppear { startTimerIfNeeded() }
        .onDisappear { timerTask?.cancel() }
    }

    // MARK: - Footer

    @ViewBuilder
    private var toolFooter: some View {
        let state = tool?.approvalState

        if state == .pending && tool?.requiresApproval == true {
            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                Text("等待批准 · 剩 \(secondsRemaining)s")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Button(action: { onReject?(); timerTask?.cancel() }) {
                    Text("拒绝")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

                Button(action: { onApprove?(); timerTask?.cancel() }) {
                    Text("同意")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.sendButton)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else {
            HStack {
                stateLabel(state)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: ApprovalState?) -> some View {
        switch state {
        case .approved, .autoApproved:
            Label("已完成", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.sendButton)
        case .rejected:
            Label("已拒绝", systemImage: "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .timedOut:
            Label("已超时", systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.secondaryText)
        case .cancelled:
            Label("已取消", systemImage: "slash.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.secondaryText)
        default:
            Label("执行中", systemImage: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.secondaryText)
        }
    }

    // MARK: - Timer

    private func startTimerIfNeeded() {
        guard tool?.approvalState == .pending, tool?.requiresApproval == true else { return }
        timerTask = Task {
            while secondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                secondsRemaining -= 1
            }
        }
    }

    // MARK: - Icon helpers

    private func iconName(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read":             return "doc.text"
        case "edit", "multiedit": return "square.and.pencil"
        case "bash", "terminal": return "terminal"
        case "write":            return "pencil.and.list.clipboard"
        case "grep", "search":   return "magnifyingglass"
        case "glob":             return "folder.badge.gearshape"
        case "ls", "list":       return "list.bullet"
        case "todoread", "todowrite": return "checklist"
        default:                 return "gearshape"
        }
    }

    private func iconColor(for toolName: String) -> Color {
        switch toolName.lowercased() {
        case "read":             return AppColors.actionText
        case "edit", "multiedit": return Color(hex: "#d97316")
        case "bash", "terminal": return Color(hex: "#22a86d")
        case "write":            return Color(hex: "#7a4fd6")
        default:                 return AppColors.secondaryText
        }
    }

    private func inputSummary(_ json: String) -> String {
        // Try to extract a path or command from the JSON
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let path = dict["path"] as? String { return path }
            if let cmd  = dict["command"] as? String { return cmd }
            if let file = dict["file_path"] as? String { return file }
        }
        // Fallback: strip braces and show first 80 chars
        let stripped = json.trimmingCharacters(in: .init(charactersIn: "{}\" "))
        return String(stripped.prefix(80))
    }
}
