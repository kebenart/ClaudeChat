import SwiftUI
import ChatKit

struct WatchChatView: View {
    @Environment(WatchAppModel.self) private var model
    let conversation: ImConversationDTO

    @State private var messages: [ImMessageDTO] = []
    @State private var draft = ""
    /// Context-window occupancy for this conversation (nil → render nothing).
    @State private var context: ConversationContext?
    /// Tapped long bubble awaiting the full-text sheet.
    @State private var full: FullText?

    /// Locally-echoed user sends, shown instantly so the bubble appears in the
    /// SAME render pass as the tap — no more "正在输入…" before your own bubble.
    /// Pruned once the server echoes the message back into `messages`.
    @State private var pending: [ImMessageDTO] = []
    /// Pending ids the server has now echoed (hide the local copy, show server's).
    @State private var confirmedPendingIds: Set<String> = []
    /// Server user-message ids already used to confirm a pending — each confirms
    /// AT MOST ONE pending, so sending the same text twice keeps both bubbles.
    @State private var claimedServerIds: Set<String> = []
    /// Pending ids whose send threw — rendered with a red "!" and tap-to-resend.
    /// These are never auto-dropped by the 120s TTL until resent/confirmed.
    @State private var failedPendingIds: Set<String> = []
    /// The failed pending currently driving the "重新发送?" confirmation dialog.
    @State private var resendTarget: ImMessageDTO?

    /// A long message collapses to a few lines; tapping opens the full sheet.
    private static func isLong(_ s: String) -> Bool {
        s.count > 220 || s.filter { $0 == "\n" }.count > 8
    }

    /// Only show real chat turns: my own text and Claude's replies. Tool/
    /// thinking/meta rows are noise on a tiny screen.
    private static let visibleKinds: Set<String> = ["text", "result", "error", "choice", "image"]

    /// The choice card currently driving the poll sheet (tapped a pending card).
    @State private var activeChoice: WatchChoiceContext?

    /// Live lastSeq from the model so the message list reloads when a reply lands.
    private var liveSeq: Int {
        model.conversations.first { $0.id == conversation.id }?.lastSeq ?? conversation.lastSeq
    }

    /// Server messages + optimistic ones the server hasn't echoed back yet.
    /// Pending rows carry seq == Int.max so they always sort last (newest).
    private var displayed: [ImMessageDTO] {
        let livePending = pending.filter { !confirmedPendingIds.contains($0.id) }
        return (messages + livePending).sorted { $0.seq < $1.seq }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(displayed, id: \.id) { m in
                        bubble(m).id(m.id)
                    }
                    if model.thinkingIds.contains(conversation.id) {
                        HStack {
                            Text(model.progressLine(for: conversation.id).map { "正在输入… · \($0)" } ?? "正在输入…")
                                .font(.system(size: 12)).foregroundStyle(.green)
                            Spacer()
                        }
                        .id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: displayed.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .top) {
            if let context {
                Text("上下文 \(context.pct)%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(model.displayName(for: conversation))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Restore this conversation's cached draft (per-conversation, local).
            if draft.isEmpty { draft = DraftStore.load(conversation.id) }
        }
        .onChange(of: draft) { _, new in
            DraftStore.save(new, for: conversation.id)
        }
        .task(id: liveSeq) {
            await reload()
            await model.markRead(conversation.id)
            // Fires on open and whenever a reply lands (liveSeq bumps).
            context = await model.fetchConversationContext(conversationId: conversation.id)
        }
        .sheet(item: $full) { ft in
            WatchFullTextView(full: ft).environment(model)
        }
        .sheet(item: $activeChoice) { ctx in
            WatchChoicePollSheet(card: ctx.card, conversationId: ctx.conversationId)
                .environment(model)
        }
        .confirmationDialog("重新发送?", isPresented: showResendDialog, presenting: resendTarget) { m in
            Button("重新发送") { resend(m) }
            Button("取消", role: .cancel) {}
        }
    }

    /// Bridges the optional `resendTarget` to the dialog's Bool binding so
    /// dismissing the dialog clears the target.
    private var showResendDialog: Binding<Bool> {
        Binding(
            get: { resendTarget != nil },
            set: { if !$0 { resendTarget = nil } }
        )
    }

    private var composer: some View {
        HStack(spacing: 6) {
            // Tapping the field opens the watch input screen, where dictation
            // (voice → text) is the default mode.
            TextField("说点什么…", text: $draft)
                .font(.system(size: 14))
            Button {
                sendTapped()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // The composer lives in a bottom safeAreaInset, so the message ScrollView
        // scrolls UNDERNEATH it. Without an opaque, fully hit-testable bar, a tap
        // near the send button fell THROUGH to the long bubble scrolled below and
        // popped its 全文 sheet. A solid background + contentShape makes the whole
        // bar (incl. the gaps around the icon) absorb the tap.
        .background(.black)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func bubble(_ m: ImMessageDTO) -> some View {
        if m.kind == "choice", let card = ChoiceCard.parse(m.content) {
            choiceBubble(card, conversationId: m.conversationId)
        } else if m.kind == "image", let card = ImageCard.parse(m.content) {
            imagePlaceholderBubble(card)
        } else {
            textBubble(m)
        }
    }

    /// Watch shows a lightweight "[图片]" placeholder for assistant images — the
    /// bytes are only rendered on Web/iOS/macOS (saves the watch the fetch).
    @ViewBuilder
    private func imagePlaceholderBubble(_ card: ImageCard) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("[图片]").font(.system(size: 14, weight: .medium))
                if let cap = card.trimmedCaption {
                    Text(cap).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact 红包-style card on the tiny watch screen. Pending → tap opens the
    /// poll sheet; answered → dimmed chip with the result summary, not tappable.
    @ViewBuilder
    private func choiceBubble(_ card: ChoiceCard, conversationId: String) -> some View {
        let accent = Color(red: 0.03, green: 0.76, blue: 0.38)
        let title = card.isExitPlanMode ? "Claude 提交了计划" : "Claude 需要选择"
        HStack(spacing: 8) {
            if card.isAnswered {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(card.answer ?? "已处理").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            } else {
                Image(systemName: card.isExitPlanMode ? "checklist" : "questionmark.bubble.fill")
                    .font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text("点击查看").font(.system(size: 10)).foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(card.isAnswered ? Color.clear : accent.opacity(0.4), lineWidth: 1))
        .opacity(card.isAnswered ? 0.85 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard !card.isAnswered else { return }
            activeChoice = WatchChoiceContext(card: card, conversationId: conversationId)
        }
    }

    private func textBubble(_ m: ImMessageDTO) -> some View {
        let mine = (m.role == "user")
        let isError = (m.kind == "error")
        // Long when the server truncated it OR the local heuristic trips.
        let long = m.isTruncated || Self.isLong(m.content)
        let failed = failedPendingIds.contains(m.id)
        return HStack(spacing: 4) {
            if mine { Spacer(minLength: 16) }
            // A failed send shows a red "!" to the LEFT of the bubble (mine is
            // right-aligned); tapping it offers 重新发送.
            if failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                    .onTapGesture { resendTarget = m }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.content.isEmpty ? " " : m.content)
                    .font(.system(size: 14))
                    .foregroundStyle(mine ? .black : (isError ? .red : .primary))
                    .lineLimit(long ? 8 : nil)
                if long {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.expand.vertical").font(.system(size: 9))
                        Text("点按查看全文").font(.system(size: 11))
                    }
                    .foregroundStyle(mine ? .black.opacity(0.7) : .green)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                mine ? Color(red: 0.03, green: 0.76, blue: 0.38)
                     : Color.gray.opacity(0.25),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                if failed { resendTarget = m }
                else if long {
                    full = FullText(content: m.content, isUser: mine,
                                    conversationId: m.conversationId,
                                    messageId: m.id, truncated: m.isTruncated)
                }
            }
            if !mine { Spacer(minLength: 16) }
        }
    }

    // MARK: - Actions

    /// Commits the optimistic bubble SYNCHRONOUSLY in the button action (same
    /// render pass as the tap) so your bubble shows instantly — the async send
    /// then runs and, on failure, flags the bubble for tap-to-resend. Mirrors
    /// iOS's sendTapped().
    private func sendTapped() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        DraftStore.clear(conversation.id)
        let id = "local-\(UUID().uuidString)"
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        pending.append(ImMessageDTO(
            id: id,
            conversationId: conversation.id,
            seq: Int.max, role: "user", kind: "text",
            content: text, createdAt: nowMs, toolTrace: nil))
        Task {
            // Pass the optimistic id as the idempotency key so a resend dedups.
            if await model.send(text: text, conversationId: conversation.id, clientMsgId: id) == false {
                failedPendingIds.insert(id)
            }
        }
    }

    /// Re-run send for a failed pending, REUSING the same bubble id so no second
    /// bubble appears. Clears the failed flag first; re-flags on another failure.
    private func resend(_ m: ImMessageDTO) {
        failedPendingIds.remove(m.id)
        let id = m.id
        let text = m.content
        Task {
            // Reuse the pending id → server dedups the retry (no double run).
            if await model.send(text: text, conversationId: conversation.id, clientMsgId: id) == false {
                failedPendingIds.insert(id)
            }
        }
    }

    private func reload() async {
        let all = await model.messages(conversation.id)
        messages = all
            .filter { Self.visibleKinds.contains($0.kind) }
            .sorted { $0.seq < $1.seq }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // Confirm optimistic echoes: pair each pending with a DISTINCT server
        // user-message by trimmed-content match, each server id claimed once.
        // Never drops an *unconfirmed* pending mid-race.
        let serverUserMsgs = messages.filter { $0.role == "user" }
        for p in pending.sorted(by: { $0.createdAt < $1.createdAt })
        where !confirmedPendingIds.contains(p.id) {
            if let match = serverUserMsgs.first(where: {
                !claimedServerIds.contains($0.id)
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    == p.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }) {
                claimedServerIds.insert(match.id)
                confirmedPendingIds.insert(p.id)
                // A confirmed echo means it sent — clear any failed flag.
                failedPendingIds.remove(p.id)
            }
        }
        // Drop confirmed + >120s-old pending — but NEVER drop a failed one (it
        // stays until resent/confirmed so tap-to-resend keeps working).
        pending.removeAll {
            confirmedPendingIds.contains($0.id)
                || ((nowMs - $0.createdAt) > 120_000 && !failedPendingIds.contains($0.id))
        }
        let liveIds = Set(pending.map(\.id))
        confirmedPendingIds = confirmedPendingIds.intersection(liveIds)
        failedPendingIds = failedPendingIds.intersection(liveIds)
        claimedServerIds = claimedServerIds.intersection(Set(messages.map(\.id)))
    }
}

/// Identifiable wrapper so a tapped choice card can drive `.sheet(item:)`.
private struct WatchChoiceContext: Identifiable {
    let id = UUID()
    let card: ChoiceCard
    let conversationId: String
}

/// The poll sheet for a choice card on watchOS. AskUserQuestion → selectable
/// option rows (checkbox/radio) + 提交; ExitPlanMode → scrollable plan + 同意/拒绝.
/// Submits over REST via `model.respondChoice(...)`, then dismisses optimistically.
private struct WatchChoicePollSheet: View {
    let card: ChoiceCard
    let conversationId: String

    @Environment(WatchAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting = false

    private let accent = Color(red: 0.03, green: 0.76, blue: 0.38)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if card.isExitPlanMode {
                        Text(card.plan ?? "")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button("拒绝") { submit(approve: false) }
                                .tint(.gray)
                            Button("同意") { submit(approve: true) }
                                .tint(accent)
                        }
                        .disabled(submitting)
                    } else {
                        questionsBody
                        Button(submitting ? "提交中…" : "提交") { submitAnswers() }
                            .tint(accent)
                            .disabled(submitting || !allAnswered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(card.isExitPlanMode ? "审阅计划" : "请选择")
        }
    }

    @ViewBuilder private var questionsBody: some View {
        ForEach(Array((card.questions ?? []).enumerated()), id: \.offset) { _, q in
            VStack(alignment: .leading, spacing: 6) {
                if let header = q.header, !header.isEmpty {
                    Text(header).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                }
                Text(q.question).font(.system(size: 13, weight: .semibold))
                ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                    optionRow(question: q, option: opt)
                }
            }
        }
    }

    private func optionRow(question: ChoiceQuestion, option: ChoiceOption) -> some View {
        let selected = selections[question.question]?.contains(option.label) ?? false
        let multi = question.allowsMultiple
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: multi
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 13))
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(question: ChoiceQuestion, label: String) {
        var set = selections[question.question] ?? []
        if question.allowsMultiple {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[question.question] = set
    }

    private var allAnswered: Bool {
        guard let qs = card.questions else { return false }
        return qs.allSatisfy { !(selections[$0.question]?.isEmpty ?? true) }
    }

    private func submitAnswers() {
        var answers: [String: [String]] = [:]
        for q in card.questions ?? [] {
            answers[q.question] = Array(selections[q.question] ?? [])
        }
        submitting = true
        Task {
            await model.respondChoice(conversationId: conversationId, requestId: card.requestId,
                                      answers: answers, approve: nil)
            dismiss()
        }
    }

    private func submit(approve: Bool) {
        submitting = true
        Task {
            await model.respondChoice(conversationId: conversationId, requestId: card.requestId,
                                      answers: nil, approve: approve)
            dismiss()
        }
    }
}

/// Identifiable wrapper so a tapped long bubble can drive `.sheet(item:)`.
private struct FullText: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let conversationId: String
    let messageId: String
    /// True when `content` is a server-side preview; the full body is lazily
    /// fetched in WatchFullTextView.
    let truncated: Bool
}

/// Full-screen scrollable view of one long message — the watch counterpart of
/// macOS's MessageFullSheet (double-click) / iOS's MarkdownSheet (查看全文). For a
/// server-truncated message it lazily fetches the full body, showing a spinner
/// while it loads and falling back to the (truncated) preview on failure.
private struct WatchFullTextView: View {
    let full: FullText
    @Environment(WatchAppModel.self) private var model
    @State private var fullContent: String?
    @State private var loading = false

    private var text: String { fullContent ?? full.content }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在加载完整内容…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .navigationTitle(full.isUser ? "我的消息" : "完整内容")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard full.truncated, fullContent == nil, !loading else { return }
            loading = true
            if let body = await model.fetchMessageContent(
                conversationId: full.conversationId, messageId: full.messageId) {
                fullContent = body
            }
            loading = false
        }
    }
}
