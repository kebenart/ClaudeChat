import ChatKit
import SwiftUI

// MARK: - ComposerView

public struct ComposerView: View {
    @Environment(AppViewModel.self) private var vm
    @Binding var text: String
    let projectPath: String?
    /// Identifier of the session this composer is attached to. Used to look up
    /// the per-session quote / attachments stored on AppViewModel.
    let sessionId: String?
    let onSend: (String) -> Void

    @FocusState private var isFocused: Bool

    @State private var commands: [CommandInfo] = []
    @State private var commandsLoaded = false
    @State private var showCommandPicker = false

    public init(text: Binding<String>,
                projectPath: String? = nil,
                sessionId: String? = nil,
                onSend: @escaping (String) -> Void) {
        self._text = text
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.onSend = onSend
    }

    private var pendingQuote: String? {
        guard let sid = sessionId else { return nil }
        return vm.composerQuotes[sid]
    }

    private var pendingImages: [PendingImage] {
        guard let sid = sessionId else { return [] }
        return vm.composerAttachments[sid] ?? []
    }

    private var pendingFiles: [String] {
        guard let sid = sessionId else { return [] }
        return vm.composerFilePaths[sid] ?? []
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the current text looks like a slash-command in-progress.
    /// `/`, `/h`, `/hel`, etc. — anything starting with `/` and no spaces yet.
    private var isSlashCommand: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ")
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Quote chip — shown when the user picked "引用" from a bubble
            // context menu. Clicking the X clears the quote for this session.
            if let q = pendingQuote {
                quoteChip(q)
            }

            // Attachment chips — images first, then file refs.
            if !pendingImages.isEmpty || !pendingFiles.isEmpty {
                attachmentStrip
            }

            // Toolbar row — `/` button is the popover anchor (left side of
            // toolbar) so the picker pops up *left-aligned* under it instead
            // of centered.
            HStack(spacing: 14) {
                Button {
                    text = "/"
                    isFocused = true
                    showCommandPicker = true
                } label: {
                    Image(systemName: "command")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Claude Code 命令 (输入 / 触发)")
                .popover(
                    isPresented: $showCommandPicker,
                    attachmentAnchor: .point(.bottomLeading),
                    arrowEdge: .top
                ) {
                    SlashCommandPicker(commands: commands,
                                       query: text.trimmingCharacters(in: .whitespaces)) { picked in
                        text = picked.name + " "
                        showCommandPicker = false
                        isFocused = true
                    }
                }

                toolbarButton(systemName: "face.smiling", help: "表情")
                toolbarButton(systemName: "paperclip",   help: "附件")
                toolbarButton(systemName: "photo",        help: "图片")
                toolbarButton(systemName: "camera.viewfinder", help: "截图")
                Spacer()
                if isSlashCommand {
                    HStack(spacing: 4) {
                        Image(systemName: "command")
                            .font(.system(size: 10))
                        Text("命令模式 — 发送将作为 Claude Code 命令执行")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(AppColors.sendButton)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(AppColors.composerBackground)

            Divider()

            // Text input area — no placeholder; extra top + leading padding
            // so the caret has a comfortable inset away from the divider.
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.primaryText)
                .scrollContentBackground(.hidden)
                .background(AppColors.composerBackground)
                .focused($isFocused)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.top, 10)
                .onChange(of: text) { _, new in
                    let trimmed = new.trimmingCharacters(in: .whitespaces)
                    let looksLikeCmd = trimmed.hasPrefix("/") && !trimmed.contains(" ")
                    // Auto-open the picker the moment the user types `/`.
                    if looksLikeCmd && !showCommandPicker {
                        showCommandPicker = true
                    }
                    // Close it once they typed past the command (added a space)
                    // or cleared the input.
                    if !looksLikeCmd && showCommandPicker {
                        showCommandPicker = false
                    }
                }

            // Footer row: hint + send button
            HStack {
                Text("↩ 发送 · ⇧↩ 换行 · / 命令")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
                Spacer()
                Button(action: sendMessage) {
                    Text(isSlashCommand ? "执行命令" : "发送(S)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(canSend ? AppColors.sendButton : AppColors.sendButton.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut("s", modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 4)
            .background(AppColors.composerBackground)
        }
        .background(AppColors.composerBackground)
        .onKeyPress(.return, phases: .down) { event in
            // ⇧↩ → newline (let TextEditor handle it)
            if event.modifiers.contains(.shift) {
                return .ignored
            }
            // ↩ or ⌘↩ → send
            sendMessage()
            return .handled
        }
        .task {
            if !commandsLoaded {
                await loadCommands()
            }
        }
        .onChange(of: projectPath) { _, _ in
            Task { await loadCommands() }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showCommandPicker = false
        onSend(trimmed)
        text = ""
    }

    private func loadCommands() async {
        do {
            commands = try await vm.apiClient.fetchCommands(projectPath: projectPath)
            commandsLoaded = true
        } catch {
            // Non-fatal — slash command UI just won't have suggestions.
        }
    }

    // MARK: - Toolbar button

    private func toolbarButton(systemName: String, help: String) -> some View {
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: 18))
                .foregroundStyle(AppColors.secondaryText)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Quote chip + attachment chips

    private func quoteChip(_ quote: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(AppColors.sendButton)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("引用消息")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.secondaryText)
                Text(quote)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.titleText)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            Button {
                if let sid = sessionId { vm.setQuote(sessionId: sid, nil) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColors.cardBackground.opacity(0.5))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingImages) { img in
                    imageChip(img)
                }
                ForEach(pendingFiles, id: \.self) { path in
                    fileChip(path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 50)
        .background(AppColors.cardBackground.opacity(0.3))
    }

    private func imageChip(_ img: PendingImage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "photo.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.sendButton)
            Text(img.filename)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(AppColors.titleText)
            Button {
                if let sid = sessionId { vm.removeImage(sessionId: sid, id: img.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppColors.claudeBubble,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(AppColors.border, lineWidth: 0.5)
        )
    }

    private func fileChip(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        return HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.secondaryText)
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(AppColors.titleText)
            Button {
                if let sid = sessionId { vm.removeFilePath(sessionId: sid, path) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppColors.claudeBubble,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(AppColors.border, lineWidth: 0.5)
        )
        .help(path)
    }
}
