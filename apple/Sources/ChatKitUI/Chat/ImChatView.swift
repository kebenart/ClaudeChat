import ChatKit
import SwiftUI

// MARK: - ImChatView
//
// IM-hub-driven chat pane for macOS (Stage 3). Renders ImMessageDTO bubbles for
// one conversation with optimistic echo + live reload, mirroring iOS's
// ChatDetailView. Replaces the provider ChatView for the chats/contacts tabs.

public struct ImChatView: View {
    @Environment(AppViewModel.self) private var vm
    let conversation: ImConversationDTO
    let chatVM: ImChatViewModel

    @State private var showTranscript = false
    @State private var context: ConversationContext?
    @State private var showAttachmentPreview: PastedText?
    /// False until we've positioned at the bottom for the current conversation.
    /// Gates animation: the first jump-to-bottom (switch / load) is instant; only
    /// later new-message appends animate.
    @State private var didInitialScroll = false

    /// A paste/edit that pushes the draft past this many chars is treated as a
    /// large blob: it's pulled OUT of the text field into a PastedText chip so
    /// SwiftUI never has to lay out the huge string. ~2k keeps the field snappy.
    private static let textAttachThreshold = 2000
    /// Hard ceiling on a single pasted-text attachment. Anything beyond this is
    /// truncated (the prompt can't usefully carry more than ~100k anyway).
    private static let maxAttachmentChars = 100_000

    public init(conversation: ImConversationDTO, chatVM: ImChatViewModel) {
        self.conversation = conversation
        self.chatVM = chatVM
    }

    private var textAttachments: [PastedText] {
        vm.composerTextAttachments[conversation.id] ?? []
    }

    private var liveConv: ImConversationDTO {
        vm.imController?.conversations.first { $0.id == conversation.id } ?? conversation
    }
    private var thinking: Bool { vm.thinkingSessionIds.contains(conversation.id) }
    /// "正在输入中…" plus the richer im:status progress line when available.
    private var typingLine: String {
        if let line = vm.progressLine(for: conversation.id) { return "正在输入中… · \(line)" }
        return "正在输入中…"
    }
    private var title: String {
        if let n = liveConv.note, !n.isEmpty { return n }
        return liveConv.title ?? String(conversation.id.prefix(8))
    }

    /// Compact a token count, e.g. 84_000 → "84k", 200_000 → "200k", 950 → "950".
    static func compactTokens(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            if k == k.rounded() { return "\(Int(k))k" }
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    private func draftBinding() -> Binding<String> {
        Binding(get: { vm.composerDrafts[conversation.id] ?? "" },
                set: {
                    vm.composerDrafts[conversation.id] = $0
                    // Persist per-conversation so a half-typed message survives
                    // app restarts and switching to another chat.
                    DraftStore.save($0, for: conversation.id)
                })
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesArea
            Divider()
            composer
        }
        .background(AppColors.background)
        .task(id: conversation.id) {
            // Hydrate this conversation's composer from the local draft cache.
            // A single ImChatView is reused across conversations, so this fires on
            // every switch; per-keystroke persistence (see draftBinding) already
            // saved the conversation we're leaving. Only fall back to the cache
            // when no in-memory draft exists so we never clobber live typing.
            if (vm.composerDrafts[conversation.id] ?? "").isEmpty {
                let cached = DraftStore.load(conversation.id)
                if !cached.isEmpty { vm.composerDrafts[conversation.id] = cached }
            }
            await chatVM.reload(conversation.id, using: vm.imController)
            await vm.markRead(sessionId: conversation.id)
            context = await vm.fetchConversationContext(conversationId: conversation.id)
        }
        // Live reload when the IM hub folds in new frames or a reply finishes.
        .onChange(of: vm.imController?.syncRevision ?? 0) { _, _ in
            Task { await chatVM.reload(conversation.id, using: vm.imController); await vm.markRead(sessionId: conversation.id) }
        }
        .onChange(of: thinking) { _, isThinking in
            if !isThinking {
                Task {
                    await chatVM.reload(conversation.id, using: vm.imController)
                    // A reply just landed — context occupancy likely changed.
                    context = await vm.fetchConversationContext(conversationId: conversation.id)
                }
            }
        }
        .sheet(isPresented: $showTranscript) {
            MacTranscriptSheet(sessionId: conversation.id, title: title)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(seed: conversation.id, title: title, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.clampedNickname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.titleText)
                if thinking {
                    Text(typingLine).font(.system(size: 11)).foregroundStyle(AppColors.sendButton)
                } else if let context {
                    Text("上下文 \(context.pct)% · \(Self.compactTokens(context.contextTokens))/\(Self.compactTokens(context.windowTokens))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            Spacer()
            if thinking {
                Button { Task { await vm.abortSession(conversation.id) } } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }.buttonStyle(.plain)
            }
            Button { showTranscript = true } label: {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(AppColors.secondaryText)
            }.buttonStyle(.plain).help("查看完整记录")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AppColors.sidebar)
    }

    // MARK: Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatVM.hasEarlier {
                        Button {
                            // Grow the window, then re-anchor to the row that was
                            // at the top so the view doesn't jump.
                            let anchor = chatVM.loadEarlier()
                            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                        } label: {
                            Text("加载更早的消息")
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.actionText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(chatVM.displayed, id: \.id) { m in
                        ImBubble(message: m, conversationId: conversation.id,
                                 selfSeed: vm.myAvatarSeed, selfTitle: vm.myDisplayName,
                                 isFailed: chatVM.isFailed(m.id),
                                 onResend: { resend(m) },
                                 onTranscript: { showTranscript = true })
                        .id(m.id)
                    }
                    if thinking { typingRow }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(16)
            }
            // New message arrives in THIS conversation → animate to the bottom.
            .onChange(of: chatVM.displayed.count) { _, _ in
                guard didInitialScroll else { return } // skip during first load
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Switching INTO a conversation (or its messages finished loading) →
            // jump to the bottom with NO animation, so the user lands already at
            // the latest message instead of watching it scroll down.
            .onChange(of: conversation.id) { _, _ in
                didInitialScroll = false
            }
            .onChange(of: chatVM.displayed.map(\.id)) { _, _ in
                if !didInitialScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)   // no withAnimation
                    didInitialScroll = true
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                didInitialScroll = true
            }
        }
    }

    private var typingRow: some View {
        HStack(spacing: 8) {
            AvatarView(seed: conversation.id, title: title, size: 28)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(AppColors.secondaryText).frame(width: 6, height: 6).opacity(0.6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
    }

    // MARK: Composer

    /// True when the current draft has any non-whitespace content. For very large
    /// drafts (a huge paste) we avoid a full `trimmingCharacters` copy — checking
    /// `isEmpty` plus a cheap first/last scan is enough and keeps typing smooth.
    private var draftHasContent: Bool {
        let s = vm.composerDrafts[conversation.id] ?? ""
        if s.isEmpty { return false }
        // Cheap path for big strings: if it's long it almost certainly has
        // content; only do the precise whitespace check on short drafts.
        if s.count > 2000 { return true }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        VStack(spacing: 6) {
            // Large-paste chips: full text lives here, NOT in the text field.
            if !textAttachments.isEmpty {
                textAttachmentStrip
            }
            HStack(spacing: 8) {
                // TextEditor (NSTextView-backed) instead of TextField(axis:.vertical):
                // the vertical-growth TextField re-measures the WHOLE string's height
                // on every edit, which froze the UI on a 90k paste. TextEditor scrolls
                // and lays out lazily; plus onChange below yanks any >2k blob out into
                // a chip so the field itself never holds a huge string.
                // IMEAwareTextEditor (NSTextView-backed) handles ↩=send / ⇧↩=newline
                // at the AppKit layer, so a ↩ that merely CONFIRMS an input-method
                // candidate (组字中) is consumed by the IME and never sends a
                // half-typed message. It also lays out large pastes lazily.
                IMEAwareTextEditor(
                    text: draftBinding(),
                    font: .systemFont(ofSize: 13),
                    onSend: { send() },
                    onChange: { handleDraftChange($0) },
                    minHeight: 34,
                    maxHeight: 120
                )
                    // ImChatView is a SINGLE reused instance across conversations,
                    // so without an identity tied to the conversation SwiftUI keeps
                    // the SAME NSTextView when you switch chats — its binding/first-
                    // responder state went stale and only the first conversation
                    // could be typed in. Keying on the id forces a fresh NSTextView
                    // (clean focus + binding) per conversation.
                    .id(conversation.id)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppColors.border, lineWidth: 0.5))
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(canSend ? AppColors.sendButton : AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AppColors.sidebar)
        .sheet(item: $showAttachmentPreview) { att in
            MessageFullSheet(content: att.content, isUser: true,
                             loading: false) { showAttachmentPreview = nil }
        }
    }

    /// Can send when there's typed text OR at least one pasted-text attachment.
    private var canSend: Bool {
        draftHasContent || !textAttachments.isEmpty
    }

    /// Detect a large paste: when the draft jumps past the threshold, pull the
    /// whole thing out into a PastedText chip and clear the field. Runs only on
    /// the rare big-paste path — normal typing returns immediately.
    private func handleDraftChange(_ newValue: String) {
        guard newValue.count > Self.textAttachThreshold else { return }
        // Move the blob into an attachment (capped at the hard ceiling), then
        // empty the text field so SwiftUI never lays out the huge string.
        let capped = newValue.count > Self.maxAttachmentChars
            ? String(newValue.prefix(Self.maxAttachmentChars))
            : newValue
        vm.addTextAttachment(sessionId: conversation.id, capped)
        vm.composerDrafts[conversation.id] = ""
        DraftStore.clear(conversation.id)
    }

    private var textAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(textAttachments) { att in
                    textChip(att)
                }
            }
        }
        .frame(maxHeight: 40)
    }

    private func textChip(_ att: PastedText) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.sendButton)
            VStack(alignment: .leading, spacing: 0) {
                Text("长文本")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.titleText)
                Text("\(att.charCount) 字符 · 点击预览")
                    .font(.system(size: 9))
                    .foregroundStyle(AppColors.secondaryText)
            }
            Button {
                vm.removeTextAttachment(sessionId: conversation.id, id: att.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppColors.border, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { showAttachmentPreview = att }
    }

    /// Synchronous optimistic insert (same render frame as the click), then send.
    private func send() {
        let typed = draftBinding().wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = textAttachments
        guard !typed.isEmpty || !attachments.isEmpty else { return }

        // Compose the real prompt: each pasted-text attachment's FULL content
        // first (in paste order), then the typed text. The user only ever saw the
        // chips + the short typed text, but the full blobs are sent for real.
        var fullText = ""
        for att in attachments { fullText += att.content + "\n\n" }
        fullText += typed
        let toSend = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toSend.isEmpty else { return }

        vm.composerDrafts[conversation.id] = ""
        DraftStore.clear(conversation.id)
        vm.composerTextAttachments[conversation.id] = nil
        let pid = chatVM.appendPending(toSend, conversationId: conversation.id)
        vm.thinkingSessionIds.insert(conversation.id)
        Task {
            let ok = await vm.sendIM(text: toSend, conversationId: conversation.id)
            if !ok { chatVM.markFailed(pid) }
        }
    }

    /// Re-send a failed optimistic bubble — reuse the SAME pending id (no
    /// duplicate), flip it back to "sending", and retry.
    private func resend(_ m: ImMessageDTO) {
        chatVM.markSending(m.id)
        vm.thinkingSessionIds.insert(conversation.id)
        Task {
            let ok = await vm.sendIM(text: m.content, conversationId: conversation.id)
            if !ok { chatVM.markFailed(m.id) }
        }
    }
}

// MARK: - ImBubble

private struct ImBubble: View {
    let message: ImMessageDTO
    let conversationId: String
    let selfSeed: String
    let selfTitle: String
    var isFailed: Bool = false
    var onResend: () -> Void = {}
    let onTranscript: () -> Void

    // Precomputed ONCE in init (not as computed properties) so scrolling doesn't
    // re-parse markdown / re-scan length / re-parse card JSON on every frame as
    // bubbles enter and leave the viewport — that re-computation was the scroll
    // jank, not the collapsing itself.
    private let isUser: Bool
    private let isError: Bool
    private let isLong: Bool
    private let choiceCard: ChoiceCard?
    private let imageCard: ImageCard?
    /// Inline-markdown for the SHORT path, parsed once.
    private let rendered: AttributedString
    /// Parsed 500-char preview for the LONG (collapsed) path, parsed once.
    private let truncatedPreview: AttributedString

    @Environment(AppViewModel.self) private var vm

    init(message: ImMessageDTO, conversationId: String, selfSeed: String,
         selfTitle: String, isFailed: Bool = false,
         onResend: @escaping () -> Void = {}, onTranscript: @escaping () -> Void) {
        self.message = message
        self.conversationId = conversationId
        self.selfSeed = selfSeed
        self.selfTitle = selfTitle
        self.isFailed = isFailed
        self.onResend = onResend
        self.onTranscript = onTranscript

        self.isUser = message.role == "user"
        self.isError = message.kind == "error"
        self.choiceCard = message.kind == "choice" ? ChoiceCard.parse(message.content) : nil
        self.imageCard = message.kind == "image" ? ImageCard.parse(message.content) : nil
        let long = message.isTruncated || MessageTextTier.tier(for: message.content) == .truncated
        self.isLong = long
        // Parse markdown ONCE for whichever path this bubble uses.
        if long {
            self.rendered = AttributedString("")
            let preview = String(message.content.prefix(500))
            self.truncatedPreview = (try? AttributedString(markdown: preview,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(preview)
        } else {
            self.truncatedPreview = AttributedString("")
            let raw = message.content.isEmpty ? " " : message.content
            self.rendered = (try? AttributedString(
                markdown: raw,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(raw)
        }
    }

    @State private var showFull = false
    @State private var showResend = false
    /// Lazily-fetched full body for a server-truncated message. nil until loaded.
    @State private var fullContent: String?
    @State private var loadingFull = false

    /// What the full sheet shows: the lazily-fetched full body once loaded, else
    /// the already-loaded (possibly truncated) content.
    private var sheetContent: String { fullContent ?? message.content }

    /// Open the full sheet; for a server-truncated message fetch the full body.
    private func openFull() {
        showFull = true
        guard message.isTruncated, fullContent == nil, !loadingFull else { return }
        loadingFull = true
        Task {
            let body = await vm.fetchMessageContent(
                conversationId: message.conversationId, messageId: message.id)
            if let body { fullContent = body }
            loadingFull = false
        }
    }

    var body: some View {
        if let card = choiceCard {
            choiceRow(card)
        } else if let img = imageCard {
            imageRow(img)
        } else {
            standardBody
        }
    }

    /// A choice card laid out like an assistant (left-aligned) bubble.
    private func choiceRow(_ card: ChoiceCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(seed: conversationId, title: "C", size: 30)
            ChoiceCardView(card: card, conversationId: conversationId)
                .environment(vm)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An image card laid out like an assistant (left-aligned) bubble.
    private func imageRow(_ card: ImageCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(seed: conversationId, title: "C", size: 30)
            ImageBubbleView(card: card)
                .environment(vm)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardBody: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                if isUser {
                    Spacer(minLength: 60)
                    if isFailed {
                        Button { showResend = true } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 16)).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain).help("发送失败,点击重发")
                        .padding(.top, 6)
                    }
                } else {
                    AvatarView(seed: conversationId, title: "C", size: 30)
                }
                bubble
                if isUser {
                    AvatarView(seed: selfSeed, title: selfTitle, size: 30)
                } else { Spacer(minLength: 60) }
            }
            .confirmationDialog("重新发送这条消息?", isPresented: $showResend) {
                Button("重新发送") { onResend() }
                Button("取消", role: .cancel) {}
            }
            if let trace = message.toolTrace, trace.count > 0 {
                Button(action: onTranscript) {
                    Label("执行了 \(trace.count) 个操作", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 11)).foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .sheet(isPresented: $showFull) {
            MessageFullSheet(content: sheetContent, isUser: isUser,
                             loading: loadingFull) { showFull = false }
        }
    }

    private var bubbleBackground: Color { isUser ? AppColors.sendButton : AppColors.claudeBubble }
    private var bubbleForeground: Color {
        isUser ? .white : (isError ? Color.red : AppColors.titleText)
    }

    /// Long messages (>= 500 chars) collapse to a fixed-height preview with a
    /// fade + hint; double-click opens MessageFullSheet — mirrors MessageBubble.
    @ViewBuilder private var bubble: some View {
        if isLong {
            truncatedBubble
                .onTapGesture(count: 2) { openFull() }
                .help("双击查看完整内容")
        } else {
            Text(rendered)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(bubbleForeground)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 460, alignment: isUser ? .trailing : .leading)
        }
    }

    private var truncatedBubble: some View {
        ZStack(alignment: .bottom) {
            Text(truncatedPreview)
                .font(.system(size: 13))
                .foregroundStyle(bubbleForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.top, 8)
                .padding(.bottom, 26)
                .frame(maxHeight: 150, alignment: .top)
                .clipped()
            LinearGradient(colors: [bubbleBackground.opacity(0), bubbleBackground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
                .allowsHitTesting(false)
            HStack(spacing: 4) {
                Image(systemName: "rectangle.expand.vertical").font(.system(size: 9))
                Text("双击查看完整 (\(message.fullLength ?? message.content.count) 字符)").font(.system(size: 10))
            }
            .foregroundStyle(isUser ? Color.white.opacity(0.85) : AppColors.sendButton)
            .padding(.bottom, 4)
        }
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 460, alignment: .leading)
    }

}
