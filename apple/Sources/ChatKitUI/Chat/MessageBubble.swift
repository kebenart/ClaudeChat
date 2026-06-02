import ChatKit
import SwiftUI

// MARK: - Text length tier

enum MessageTextTier {
    /// `< 500 chars` — render the full bubble inline.
    case short
    /// `>= 500 chars` — show a truncated preview (~140pt height). Double-click
    /// opens `MessageFullSheet` with proper markdown rendering.
    case truncated

    static func tier(for content: String) -> MessageTextTier {
        content.count < 500 ? .short : .truncated
    }
}

// MARK: - MessageBubble

public struct MessageBubble: View {
    let message: ChatMessage
    let onApprove: (() -> Void)?
    let onReject: (() -> Void)?
    let onQuote: ((String) -> Void)?
    /// My (outgoing) avatar seed/title — passed from ChatView so it matches the
    /// 我 sidebar. Defaults keep previews/stubs working without an AppViewModel.
    let selfSeed: String
    let selfTitle: String

    @Environment(\.chatFontSize) private var fontSize
    @State private var showFullSheet = false

    public init(message: ChatMessage,
                onApprove: (() -> Void)? = nil,
                onReject: (() -> Void)? = nil,
                onQuote: ((String) -> Void)? = nil,
                selfSeed: String = "me",
                selfTitle: String = "M") {
        self.message = message
        self.onApprove = onApprove
        self.onReject = onReject
        self.onQuote = onQuote
        self.selfSeed = selfSeed
        self.selfTitle = selfTitle
    }

    private var isUser: Bool { message.role == .user }

    /// Max bubble width. Picked to fit ~70 monospace columns of code while
    /// keeping plain chat text from sprawling across a wide window.
    private static let maxBubbleWidth: CGFloat = 520

    public var body: some View {
        if message.role == .tool, let tool = message.toolUse {
            // Tool card — always left-aligned
            HStack(alignment: .top, spacing: 8) {
                claudeAvatar
                ToolCard(message: message, onApprove: onApprove, onReject: onReject)
                    .frame(maxWidth: Self.maxBubbleWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                if isUser {
                    Spacer(minLength: 60)
                    // Status icon + bubble travel together so the indicator
                    // sits flush against the bubble regardless of width.
                    HStack(alignment: .top, spacing: 4) {
                        userStatusIndicator
                        bubbleBody
                            .contextMenu { bubbleContextMenu }
                    }
                    .frame(maxWidth: Self.maxBubbleWidth, alignment: .trailing)
                    userAvatar
                } else {
                    claudeAvatar
                    bubbleBody
                        .frame(maxWidth: Self.maxBubbleWidth, alignment: .leading)
                        .contextMenu { bubbleContextMenu }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Right-click menu on a chat bubble. WeChat-style: 引用 / 复制 / (失败时) 查看错误.
    @ViewBuilder
    private var bubbleContextMenu: some View {
        if let onQuote {
            Button {
                onQuote(message.content)
            } label: {
                Label("引用", systemImage: "text.quote")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if message.sendStatus == .failed, let err = message.sendError {
            Divider()
            Button {
                let alert = NSAlert()
                alert.messageText = "发送失败"
                alert.informativeText = err
                alert.runModal()
            } label: {
                Label("查看失败原因", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// WeChat-style send-status indicator next to a USER bubble:
    /// .sending → spinning clock · .sent → single check ·
    /// .delivered → double check · .failed → red ❗ with popover.
    @ViewBuilder
    private var userStatusIndicator: some View {
        switch message.sendStatus {
        case .sending:
            ProgressView()
                .controlSize(.mini)
                .padding(.top, 12)
                .padding(.trailing, -2)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText)
                .padding(.top, 12)
                .padding(.trailing, -2)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.sendButton)
                .padding(.top, 12)
                .padding(.trailing, -2)
        case .failed:
            sendFailedIndicator
        case .none:
            EmptyView()
        }
    }

    /// WeChat-style red exclamation circle adjacent to a failed user bubble.
    /// Click → popover showing the reason.
    @State private var showSendErrorPopover = false
    private var sendFailedIndicator: some View {
        Button {
            showSendErrorPopover.toggle()
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .padding(.top, 10)
                .padding(.trailing, -2)   // visually hug the bubble's left edge
        }
        .buttonStyle(.plain)
        .help("点击查看失败原因")
        .popover(isPresented: $showSendErrorPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("发送失败").font(.system(size: 13, weight: .semibold))
                }
                Text(message.sendError ?? "未知原因。请检查网络或重新登录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("提示:这条消息已经发出,但服务端没有返回结果。如果会话仍在使用,可以重新发送一次。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(minWidth: 280, maxWidth: 380)
        }
    }

    // MARK: - Bubble body

    @ViewBuilder
    private var bubbleBody: some View {
        let segments = parseMarkdownSegments(message.content)
        let hasOnlyText = segments.allSatisfy { if case .text = $0 { return true }; return false }
        let rawText = message.content
        let hasMarkdownStructure = hasHeadingsOrLists(rawText)

        // Single rule: short text → inline bubble; longer than 500 chars (or
        // contains code blocks / markdown structure) → truncated preview with
        // double-click → MessageFullSheet for the full rendered version.
        let needsTruncation = !hasOnlyText
            || hasMarkdownStructure
            || MessageTextTier.tier(for: rawText) == .truncated

        if !needsTruncation {
            plainBubble(rawText)
        } else {
            truncatedBubble(rawText)
                .onTapGesture(count: 2) { showFullSheet = true }
                .help("双击查看完整内容")
                .sheet(isPresented: $showFullSheet) {
                    MessageFullSheet(content: rawText, isUser: isUser) {
                        showFullSheet = false
                    }
                }
        }
    }

    // MARK: - Plain bubble

    private func plainBubble(_ text: String) -> some View {
        let attrString = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attrString)
            .font(AppFont.message(size: fontSize))
            .foregroundStyle(isUser ? AppColors.userBubbleText : AppColors.claudeBubbleText)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? AppColors.userBubble : AppColors.claudeBubble,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: isUser ? .topTrailing : .topLeading) { bubbleTail }
            .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
    }

    /// WeChat-style triangle tail pointing toward the avatar.
    private var bubbleTail: some View {
        BubbleTail()
            .fill(isUser ? AppColors.userBubble : AppColors.claudeBubble)
            .frame(width: 6, height: 8)
            .scaleEffect(x: isUser ? 1 : -1, y: 1, anchor: .center)
            .offset(x: isUser ? 5 : -5, y: 10)
    }

    // MARK: - Truncated bubble (≥ 500 chars OR contains markdown / code)
    //
    // Renders a fixed-height preview with a fade. Double-click anywhere on
    // the bubble opens MessageFullSheet for the fully-rendered version.

    @ViewBuilder
    private func truncatedBubble(_ text: String) -> some View {
        let preview = String(text.prefix(500))
        let attrString = (try? AttributedString(markdown: preview,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(preview)
        ZStack(alignment: .bottom) {
            Text(attrString)
                .font(AppFont.message(size: fontSize))
                .foregroundStyle(isUser ? AppColors.userBubbleText : AppColors.claudeBubbleText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxHeight: 140, alignment: .top)
                .clipped()

            // Gradient fade
            LinearGradient(
                colors: [
                    (isUser ? AppColors.userBubble : AppColors.claudeBubble).opacity(0),
                    isUser ? AppColors.userBubble : AppColors.claudeBubble
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            // Footer hint
            HStack(spacing: 4) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 9))
                Text("双击查看完整 (\(text.count) 字符)")
                    .font(.system(size: 10))
            }
            .foregroundStyle(AppColors.actionText)
            .padding(.bottom, 4)
        }
        .background(isUser ? AppColors.userBubble : AppColors.claudeBubble,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: isUser ? .topTrailing : .topLeading) { bubbleTail }
        .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
    }

    // MARK: - Mixed bubble (text + code blocks + headings/lists)

    private func mixedBubble(_ segments: [ContentSegment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let t):
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdownText(t)
                    }
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUser ? AppColors.userBubble : AppColors.claudeBubble,
                    in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
    }

    /// Render a markdown text segment, recognising headings (#, ##, ###) and
    /// bullet/numbered lists. Inline emphasis goes through `AttributedString(markdown:)`.
    @ViewBuilder
    private func markdownText(_ raw: String) -> some View {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.drop { $0 == " " }   // count leading spaces but render trimmed
        let textColor: Color = isUser ? AppColors.userBubbleText : AppColors.claudeBubbleText

        if trimmed.hasPrefix("### ") {
            Text(inlineAttr(String(trimmed.dropFirst(4))))
                .font(.system(size: fontSize.cgFloat + 1, weight: .semibold))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("## ") {
            Text(inlineAttr(String(trimmed.dropFirst(3))))
                .font(.system(size: fontSize.cgFloat + 2, weight: .semibold))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("# ") {
            Text(inlineAttr(String(trimmed.dropFirst(2))))
                .font(.system(size: fontSize.cgFloat + 4, weight: .bold))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(textColor.opacity(0.7))
                Text(inlineAttr(String(trimmed.dropFirst(2))))
                    .font(AppFont.message(size: fontSize))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
            }
        } else if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let marker = String(trimmed[trimmed.startIndex..<m.upperBound])
            let body = String(trimmed[m.upperBound...])
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker.trimmingCharacters(in: .whitespaces))
                    .foregroundStyle(textColor.opacity(0.7))
                    .font(AppFont.message(size: fontSize))
                Text(inlineAttr(body))
                    .font(AppFont.message(size: fontSize))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
            }
        } else if trimmed.hasPrefix("> ") {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(textColor.opacity(0.3))
                    .frame(width: 3)
                Text(inlineAttr(String(trimmed.dropFirst(2))))
                    .font(AppFont.message(size: fontSize))
                    .foregroundStyle(textColor.opacity(0.85))
                    .textSelection(.enabled)
            }
            .padding(.leading, 2)
        } else {
            Text(inlineAttr(String(line)))
                .font(AppFont.message(size: fontSize))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineAttr(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Cheap check: does the text contain any heading / list / blockquote line?
    /// Avoids paying for the line-by-line renderer on simple paragraph chat.
    private func hasHeadingsOrLists(_ text: String) -> Bool {
        for line in text.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ")
                || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("> ") {
                return true
            }
            if t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    // MARK: - Avatars

    private var claudeAvatar: some View {
        // Incoming avatar = the conversation's avatar (seeded by sessionId) so
        // it matches the sidebar row, like the web client.
        AvatarView(seed: message.sessionId, title: "C", size: 36)
    }

    private var userAvatar: some View {
        AvatarView(seed: selfSeed, title: selfTitle, size: 36)
    }
}

/// Small triangle, pointed end on the right. Mirror via `.scaleEffect(x: -1)`
/// for the Claude-side bubble.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Bubbles") {
    let shortMsg = ChatMessage(id: "1", sessionId: "s", role: .user,
                               content: "那 SwiftData schema 怎么写?")
    let longMsg = ChatMessage(id: "2", sessionId: "s", role: .assistant,
                              content: String(repeating: "这是一段比较长的回复内容。", count: 50))
    let codeMsg = ChatMessage(id: "3", sessionId: "s", role: .assistant,
                              content: "以下是示例:\n```swift\nlet x = 42\nprint(x)\n```\n希望有帮助。")
    return ScrollView {
        VStack(spacing: 14) {
            MessageBubble(message: shortMsg)
            MessageBubble(message: longMsg)
            MessageBubble(message: codeMsg)
        }
        .padding()
    }
    .environment(\.chatFontSize, .medium)
    .frame(width: 600, height: 500)
}
#endif
