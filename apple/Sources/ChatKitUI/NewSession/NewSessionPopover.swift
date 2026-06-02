import ChatKit
import SwiftUI

// MARK: - NewSessionPopover

/// Popover for starting a new chat. Mirrors the "add friend" flow in WeChat:
/// type a path (or pick from suggestions), optionally give a nickname, then
/// the default greeting "hello" is sent. The user can edit the greeting too.
public struct NewSessionPopover: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var pathText: String = ""
    @State private var note: String = ""
    @State private var firstPrompt: String = "hello"
    /// Distinct project paths drawn from existing contacts (sessions). When
    /// adding a new contact, the user usually wants to reuse a path they've
    /// already worked with — these are surfaced as one-click chips.
    @State private var suggestions: [PathSuggestion] = []
    @State private var isCreating = false
    @State private var errorMessage: String? = nil

    struct PathSuggestion: Identifiable, Hashable {
        let path: String
        let displayName: String
        let sessionCount: Int
        var id: String { path }
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble")
                    .foregroundStyle(AppColors.sendButton)
                Text("新建会话")
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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Path input
                    VStack(alignment: .leading, spacing: 6) {
                        labelText("项目路径")
                        TextField("/Users/you/your-project", text: $pathText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Text("从下方已有联系人选一个路径,或手输绝对路径开新会话")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.tertiaryText)
                    }

                    // Suggestions — distinct paths from existing contacts
                    if !filteredSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            labelText("已知联系人路径 (\(filteredSuggestions.count))")
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(filteredSuggestions) { s in
                                    suggestionRow(s)
                                }
                            }
                        }
                    }

                    Divider()

                    // Optional nickname
                    VStack(alignment: .leading, spacing: 6) {
                        labelText("备注 (可选)")
                        TextField("给这个会话起个名字", text: $note)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    // First message (defaults to "hello")
                    VStack(alignment: .leading, spacing: 6) {
                        labelText("首条消息")
                        TextField("hello", text: $firstPrompt, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Text("像微信「打招呼」,默认发 hello 让 Claude 启动会话")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.tertiaryText)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 480)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: { Task { await createSession() } }) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("发起会话", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.sendButton)
                .disabled(pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
            .padding(16)
        }
        .frame(width: 380)
        .task {
            await loadSuggestions()
        }
    }

    // MARK: - Subviews

    private func labelText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColors.secondaryText)
            .textCase(.uppercase)
    }

    private func suggestionRow(_ s: PathSuggestion) -> some View {
        Button(action: { pathText = s.path }) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.titleText)
                    Text(s.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if s.sessionCount > 1 {
                    Text("\(s.sessionCount) 个会话")
                        .font(.system(size: 9))
                        .foregroundStyle(AppColors.tertiaryText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(AppColors.cardIconBackground, in: Capsule())
                }
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private var filteredSuggestions: [PathSuggestion] {
        let q = pathText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return suggestions }
        return suggestions.filter {
            $0.path.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    // MARK: - Actions

    /// Build the suggestion list from distinct project paths across ALL
    /// existing sessions (including hidden ones, since the user might be
    /// re-opening a workspace they previously archived).
    private func loadSuggestions() async {
        let allSessions = await vm.storage.listSessions(includingHidden: true)
        var grouped: [String: (name: String, count: Int)] = [:]
        for s in allSessions {
            let path = s.projectPath
            guard !path.isEmpty else { continue }
            let name = s.projectDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (path as NSString).lastPathComponent
            if let existing = grouped[path] {
                grouped[path] = (existing.name, existing.count + 1)
            } else {
                grouped[path] = (name.isEmpty ? path : name, 1)
            }
        }
        suggestions = grouped.map { (path, info) in
            PathSuggestion(path: path, displayName: info.name, sessionCount: info.count)
        }
        .sorted { $0.sessionCount > $1.sessionCount }
    }

    private func createSession() async {
        let path = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let prompt: String = {
            let p = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? "hello" : p
        }()

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        guard let newId = await vm.createSession(projectPath: path, firstPrompt: prompt) else {
            errorMessage = vm.lastCreateSessionError
                ?? "创建会话失败,请检查服务器连接和路径"
            return
        }

        // Apply optional nickname.
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            // Routes through the IM hub so the note syncs cross-device.
            await vm.setNote(sessionId: newId, trimmedNote)
        }
        await vm.selectSession(newId)
        // Refresh sidebar so the new session (with note) shows up immediately.
        await vm.loadSessions()
        dismiss()
    }
}
