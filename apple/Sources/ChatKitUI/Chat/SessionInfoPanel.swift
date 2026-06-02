import ChatKit
import SwiftUI

// MARK: - SessionInfoPanel
//
// WeChat-style "查看资料" card — slides in from the right when the user taps the
// `...` button in the chat header. Owns nickname editing, pin toggle, workspace
// path display, and the soft-delete action.

public struct SessionInfoPanel: View {
    @Environment(AppViewModel.self) private var vm
    let session: SessionInfo
    let onClose: () -> Void

    @State private var noteDraft: String = ""
    @State private var pinned: Bool = false

    public init(session: SessionInfo, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header bar with close button
            HStack {
                Text("会话信息")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(AppColors.background)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Avatar + display name
                    HStack(spacing: 12) {
                        AvatarView(seed: session.id, title: session.displayName, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.displayName)
                                .font(.system(size: 16, weight: .medium))
                            Text("会话 ID · \(String(session.id.prefix(8)))…")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppColors.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }

                    Divider()

                    // Nickname
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("昵称")
                        TextField("给会话起个名字", text: $noteDraft, onCommit: saveNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                        Text("留空将显示项目名作为标题")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.tertiaryText)
                        if noteDraft != (session.note ?? "") {
                            HStack {
                                Spacer()
                                Button("保存", action: saveNote)
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppColors.sendButton)
                                    .controlSize(.small)
                            }
                        }
                    }

                    Divider()

                    // Pin toggle
                    HStack {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(pinned ? AppColors.sendButton : AppColors.tertiaryText)
                            .frame(width: 18)
                        Text("置顶聊天")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: $pinned)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(AppColors.sendButton)
                            .onChange(of: pinned) { _, new in
                                Task {
                                    await vm.storage.setPinned(sessionId: session.id, new)
                                    await vm.loadSessions()
                                }
                            }
                    }

                    Divider()

                    // Workspace path ("address")
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("项目路径")
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(AppColors.secondaryText)
                            Text(session.projectPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppColors.titleText)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.projectPath, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .help("复制路径")
                        }
                        .padding(8)
                        .background(AppColors.cardIconBackground, in: RoundedRectangle(cornerRadius: 4))
                        if let displayName = session.projectDisplayName,
                           displayName != session.projectPath {
                            Text(displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(AppColors.tertiaryText)
                        }
                    }

                    Divider()

                    // Activity info
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("活动")
                        if let last = session.lastActivityAt {
                            metaRow(icon: "clock", text: relativeDateString(last))
                        }
                        if let count = session.messageCount {
                            metaRow(icon: "text.bubble", text: "\(count) 条消息")
                        }
                    }

                    Spacer(minLength: 24)

                    // Destructive action
                    Button(role: .destructive) {
                        Task {
                            await vm.softDeleteSession(session.id)
                            onClose()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label("从列表中删除", systemImage: "eye.slash")
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(18)
            }
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            noteDraft = session.note ?? session.title ?? ""
            pinned = session.isPinned
        }
        .onChange(of: session.id) { _, _ in
            noteDraft = session.note ?? session.title ?? ""
            pinned = session.isPinned
        }
    }

    // MARK: - Subviews

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppColors.secondaryText)
            .textCase(.uppercase)
    }

    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.titleText)
        }
    }

    // MARK: - Actions

    private func saveNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // Routes through the IM hub so the note syncs cross-device.
            await vm.setNote(sessionId: session.id, trimmed.isEmpty ? nil : trimmed)
        }
    }

    private func relativeDateString(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return "今天 \(f.string(from: date))"
        }
        if cal.isDateInYesterday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return "昨天 \(f.string(from: date))"
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
