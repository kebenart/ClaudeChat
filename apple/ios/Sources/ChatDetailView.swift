import SwiftUI
import ChatKit

struct ChatDetailView: View {
    let conversation: ImConversationDTO
    @Environment(IOSAppModel.self) private var model
    @State private var messages: [ImMessageDTO] = []
    /// Locally-echoed user messages shown instantly; pruned once the server's
    /// copy lands in `messages`.
    @State private var pending: [ImMessageDTO] = []
    @State private var draftText: String = ""
    @State private var showTranscript: Bool = false
    /// Debounces the reload+markRead triggered by lastSeq changes so a burst of
    /// incoming messages (or a flaky network's reconnect churn) coalesces into one
    /// full-message reload instead of one per seq tick.
    @State private var reloadTask: Task<Void, Never>?
    @State private var showRename: Bool = false
    @State private var renameText: String = ""
    /// The choice card whose poll is open. Presented as a sheet from THIS stable
    /// view (not the message row) so a live message-list reload can't tear down
    /// the poll mid-answer (which reset selections + dismissed the keyboard).
    @State private var activeChoice: ChoiceCard?
    @State private var commands: [CommandInfo] = []
    /// Current context-window occupancy for this conversation (read-only).
    /// nil → no data yet, render nothing.
    @State private var context: ConversationContext?

    /// True while a "加载更早的消息" page is being fetched from the server.
    @State private var loadingOlder: Bool = false
    /// Whether there are more older messages to show (more local beyond the
    /// window, or the server may still have older). Hides the top affordance.
    @State private var hasMoreOlder: Bool = true
    /// Recent-message window: the chat loads only the most-recent `windowLimit`
    /// on open (the whole long conversation no longer hits memory on every
    /// reload). Each "加载更早" grows it by a page.
    @State private var windowLimit: Int = 80
    /// Whether the SERVER may still have messages older than everything local.
    @State private var serverHasMore: Bool = true
    private static let windowPage = 40

    /// Live conversation state (the passed-in value is a snapshot from nav).
    private var liveConv: ImConversationDTO {
        model.conversations.first { $0.id == conversation.id } ?? conversation
    }

    /// Slash-command candidates: shown while the draft is a single "/word" token.
    private var slashMatches: [CommandInfo] {
        let t = draftText
        guard t.hasPrefix("/"), !t.contains(" "), !t.contains("\n") else { return [] }
        let q = t.lowercased()
        return Array(commands.filter { q == "/" || $0.name.lowercased().hasPrefix(q) }.prefix(8))
    }

    private var thinking: Bool { model.thinkingConversationIds.contains(conversation.id) }

    /// Ids of optimistic messages the server has now echoed back (so we hide the
    /// local copy and show the server's). Tracked by id, set during reload —
    /// the displayed list never drops a pending message mid-render-race.
    @State private var confirmedPendingIds: Set<String> = []

    /// Server message ids already used to confirm a pending echo. A given server
    /// message confirms AT MOST ONE pending for its whole lifetime, so sending
    /// the same text twice no longer collapses both optimistic bubbles onto the
    /// first echo.
    @State private var claimedServerIds: Set<String> = []

    /// Pending ids whose send threw — rendered with a red "!" + tap-to-resend,
    /// and exempt from the 120s pending TTL until resent/confirmed.
    @State private var failedPendingIds: Set<String> = []

    /// Message kinds worth rendering as chat bubbles. The IM hub also stores
    /// tool_use / thinking / tool_result / meta rows; those are noise in the
    /// thread (the full record is behind 查看完整记录), so we never bubble them.
    private static let bubbleKinds: Set<String> = ["text", "result", "error", "choice", "image"]

    /// Server messages + optimistic ones the server hasn't echoed back yet.
    private var displayed: [ImMessageDTO] {
        let livePending = pending.filter { !confirmedPendingIds.contains($0.id) }
        return messages + livePending
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    loadOlderRow(proxy: proxy)
                    ForEach(renderItems) { item in
                        switch item {
                        case .divider(let id, let label):
                            Text(label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .id(id)
                        case .message(let m):
                            IOSMessageBubble(message: m, conversation: conversation,
                                             isFailed: failedPendingIds.contains(m.id),
                                             onResend: { resend(m) },
                                             onOpenChoice: { activeChoice = $0 })
                                .id(m.id)
                        }
                    }
                    if thinking { typingRow }
                    // Breathing room so the newest bubble never sits flush
                    // against the composer.
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            .background(WC.chatBg)
            // Pin the view to the bottom: new messages and streaming growth push
            // content up smoothly instead of appearing flush and then jumping.
            .defaultScrollAnchor(.bottom)
            .onChange(of: thinking) { _, isThinking in
                // When the reply finishes, pull the latest so the assistant
                // message is shown even if a live frame was missed.
                if !isThinking {
                    Task {
                        await reload()
                        await model.markRead(conversation.id)
                        // Context grows after each reply — refresh it here.
                        context = await model.fetchConversationContext(conversationId: conversation.id)
                    }
                }
            }
            }

            if !slashMatches.isEmpty { slashPicker }
            Divider()
            composerBar
        }
        .sheet(item: $activeChoice) { card in
            IOSChoicePollSheet(card: card, conversationId: conversation.id)
                .environment(model)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.displayName(for: conversation).clampedNickname)
                        .font(.system(size: 16, weight: .semibold))
                    if thinking {
                        Text("正在输入中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    } else if let context {
                        Text("上下文 \(context.pct)% · \(Self.compactTokens(context.contextTokens))/\(Self.compactTokens(context.windowTokens))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if thinking {
                    Button { Task { await model.abort(conversation.id) } } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
                Menu {
                    Button {
                        renameText = liveConv.note ?? conversation.title ?? ""
                        showRename = true
                    } label: { Label("设置备注名", systemImage: "pencil") }
                    Button {
                        Task { await model.setPinned(conversation.id, !liveConv.isPinned) }
                    } label: {
                        Label(liveConv.isPinned ? "取消置顶" : "置顶",
                              systemImage: liveConv.isPinned ? "pin.slash" : "pin")
                    }
                    Button {
                        Task { await model.setMuted(conversation.id, !liveConv.isMuted) }
                    } label: {
                        Label(liveConv.isMuted ? "取消免打扰" : "消息免打扰",
                              systemImage: liveConv.isMuted ? "bell" : "bell.slash")
                    }
                    Button {
                        model.setFolded(conversation.id, !model.isFolded(conversation.id))
                    } label: {
                        Label(model.isFolded(conversation.id) ? "取消折叠" : "折叠会话",
                              systemImage: "rectangle.stack")
                    }
                    Divider()
                    Button {
                        showTranscript = true
                    } label: { Label("查看完整记录", systemImage: "doc.text.magnifyingglass") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("设置备注名", isPresented: $showRename) {
            TextField("备注名（最多10字）", text: $renameText)
            Button("保存") { model.setNote(conversation.id, renameText) }
            Button("清除", role: .destructive) { model.setNote(conversation.id, nil) }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(conversation: conversation)
                .environment(model)
        }
        // FAST PATH: show this conversation's local messages immediately. This is
        // the ONLY thing the first frame waits on, so the chat never sits blank
        // while a network sync is in flight (the old code awaited syncNow() here,
        // which blocked the whole screen until a full paged sync finished — and
        // hung forever if that sync stalled).
        .task(id: conversation.id) {
            model.foregroundConversationId = conversation.id
            await reload()
            await model.markRead(conversation.id)
        }
        // SLOW PATH: best-effort catch-up, in a SEPARATE `.task` so SwiftUI cancels
        // it when the view goes away (no leaked syncs piling onto the serial
        // Storage actor). Pulls anything that landed while we were gone, folds it
        // in, and loads the subtle extras.
        .task(id: conversation.id) {
            await model.syncNow()
            await reload()
            if commands.isEmpty { commands = await model.availableCommands() }
            context = await model.fetchConversationContext(conversationId: conversation.id)
        }
        .onAppear {
            // Restore this conversation's cached draft (per-conversation, local).
            if draftText.isEmpty { draftText = DraftStore.load(conversation.id) }
        }
        .onChange(of: draftText) { _, new in
            DraftStore.save(new, for: conversation.id)
        }
        .onDisappear {
            if model.foregroundConversationId == conversation.id {
                model.foregroundConversationId = nil
            }
        }
        .onChange(of: model.connectionState) { old, new in
            // Auto-flush the outbox while the chat is open: on the edge INTO
            // .online (not every state change), resend every failed pending
            // message. Each reuses its own id as the idempotency key, so the
            // server dedups if the original actually landed.
            guard new == .online, old != .online else { return }
            let toResend = pending.filter { failedPendingIds.contains($0.id) }
            for m in toResend { resend(m) }
        }
        .onChange(of: model.conversations.first(where: { $0.id == conversation.id })?.lastSeq) { _, _ in
            // Coalesce bursts (and a flaky network's reconnect churn) into ONE
            // reload+markRead ~300ms after the last seq change, instead of a full
            // message reload + a network markRead per tick.
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await reload()
                await model.markRead(conversation.id)
            }
        }
    }

    // MARK: - Load older history

    /// Top affordance: a tappable row that back-fills one page of older
    /// messages. Hidden once `hasMoreOlder` is false (server returned a short
    /// page) or while there are no messages yet to anchor a "before" cursor.
    @ViewBuilder
    private func loadOlderRow(proxy: ScrollViewProxy) -> some View {
        if hasMoreOlder && !messages.isEmpty {
            Button {
                Task { await loadOlder(proxy: proxy) }
            } label: {
                HStack(spacing: 6) {
                    if loadingOlder {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 11))
                    }
                    Text(loadingOlder ? "正在加载…" : "加载更早的消息")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(loadingOlder)
            .id("load-older-row")
        }
    }

    /// Fetch the page of messages just before the oldest currently-loaded one,
    /// write them to local storage, reload, and pin the viewport to the message
    /// that was previously at the top so the view doesn't jump.
    private func loadOlder(proxy: ScrollViewProxy) async {
        guard !loadingOlder, let anchorId = messages.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        // 1) Grow the window to reveal more LOCAL history first (cheap, no net).
        windowLimit += Self.windowPage
        await reload()
        // 2) If the window now exceeds everything local, back-fill one page from
        //    the server (the oldest shown message is now the true oldest local).
        let localCount = await model.localMessageCount(conversation.id)
        if windowLimit > localCount, let oldestLocal = messages.first {
            serverHasMore = await model.loadOlder(conversationId: conversation.id, beforeSeq: oldestLocal.seq)
            await reload()
        }
        // Keep the previously-topmost message in view (no jump to bottom).
        proxy.scrollTo(anchorId, anchor: .top)
    }

    // MARK: - Typing indicator

    private var typingRow: some View {
        HStack(alignment: .top, spacing: 8) {
            IOSAvatar(seed: conversation.id, title: conversation.title ?? "C", size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.secondary).frame(width: 6, height: 6).opacity(0.6)
                    }
                }
                if let line = model.progressLine(for: conversation.id) {
                    Text("正在输入… · \(line)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(WC.bubbleIn, in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 40)
        }
        .id("typing")
    }

    // MARK: - Slash command picker

    private var slashPicker: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(slashMatches) { cmd in
                    Button {
                        draftText = cmd.name + " "
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cmd.namespace == "skill" ? "sparkles" : "terminal")
                                .font(.system(size: 13))
                                .foregroundStyle(WC.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cmd.name)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                if !cmd.description.isEmpty {
                                    Text(cmd.description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 44)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color(.systemBackground))
    }

    // MARK: - Composer

    private var composerBar: some View {
        HStack(spacing: 8) {
            // NEVER disabled — a send (and its reconnect-retry on a bad network)
            // runs in the background, so the input must stay live for the next
            // message. Disabling it here is what froze typing when the网 was poor.
            TextField("发送消息…", text: $draftText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Button {
                sendTapped()
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : WC.accent)
                    .imageScale(.large)
            }
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .safeAreaPadding(.bottom)
    }

    // MARK: - Actions

    /// Runs synchronously in the button action so the optimistic bubble is
    /// committed in the SAME render pass as the tap — appending inside the async
    /// Task instead made the bubble appear a cycle *after* the typing indicator.
    private func sendTapped() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftText = ""
        DraftStore.clear(conversation.id)
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // Commit the optimistic bubble AND the typing indicator in the SAME
        // synchronous transaction so SwiftUI renders them together.
        let pid = "local-\(UUID().uuidString)"
        pending.append(ImMessageDTO(
            id: pid,
            conversationId: conversation.id,
            seq: Int.max, role: "user", kind: "text",
            content: text, createdAt: nowMs, toolTrace: nil))
        model.thinkingConversationIds.insert(conversation.id)
        // Fire-and-forget — do NOT hold the composer while send (+ its slow
        // reconnect-retry on a poor network) runs. The optimistic bubble is the
        // feedback; a failure flips it to a red tap-to-resend.
        Task {
            let ok = await model.send(text: text, conversationId: conversation.id, clientMsgId: pid)
            if !ok { failedPendingIds.insert(pid) }
        }
    }

    /// Re-send a failed optimistic bubble — reuse the SAME pending id (no
    /// duplicate), flip it back to "sending", and retry.
    private func resend(_ m: ImMessageDTO) {
        failedPendingIds.remove(m.id)
        model.thinkingConversationIds.insert(conversation.id)
        Task {
            // Reuse the pending id as the idempotency key so the server dedups a
            // retry (manual tap or auto-flush) instead of re-invoking Claude.
            let ok = await model.send(text: m.content, conversationId: conversation.id, clientMsgId: m.id)
            if !ok { failedPendingIds.insert(m.id) }
        }
    }

    private func reload() async {
        // Window to the most-recent `windowLimit` RAW rows (grows via 加载更早).
        let all = await model.messages(conversation.id, limit: windowLimit)
        // Only bubble real chat turns — drop tool_use / thinking / tool_result /
        // meta rows that would otherwise render as blank/garbage bubbles.
        messages = all.filter { Self.bubbleKinds.contains($0.kind) }
        // More to show if local has rows beyond the window, or the server might.
        let localCount = await model.localMessageCount(conversation.id)
        hasMoreOlder = (all.count < localCount) || serverHasMore
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // Confirm optimistic echoes by pairing each pending with a DISTINCT
        // server user-message (content match, each server id consumed once and
        // for all). This stops two identical sends from both collapsing onto the
        // first echo, and never drops an *unconfirmed* pending mid-race.
        let serverUserMsgs = messages.filter { $0.role == "user" }
        for p in pending.sorted(by: { $0.createdAt < $1.createdAt })
        where !confirmedPendingIds.contains(p.id) {
            if let match = serverUserMsgs.first(where: {
                !claimedServerIds.contains($0.id) && $0.content.trimmed == p.content.trimmed
            }) {
                claimedServerIds.insert(match.id)
                confirmedPendingIds.insert(p.id)
            }
        }
        pending.removeAll { confirmedPendingIds.contains($0.id) || ((nowMs - $0.createdAt) > 120_000 && !failedPendingIds.contains($0.id)) }
        confirmedPendingIds = confirmedPendingIds.intersection(Set(pending.map(\.id)))
        // Keep claimed-id set from growing without bound.
        claimedServerIds = claimedServerIds.intersection(Set(messages.map(\.id)))
        failedPendingIds = failedPendingIds.intersection(Set(pending.map(\.id)))
    }

    // MARK: - Render items (interleave time dividers)

    private enum RenderItem: Identifiable {
        case divider(id: String, label: String)
        case message(ImMessageDTO)
        var id: String {
            switch self {
            case .divider(let id, _): return id
            case .message(let m): return m.id
            }
        }
    }

    private var renderItems: [RenderItem] {
        var items: [RenderItem] = []
        var prev: Int?
        for m in displayed {
            let gap = prev.map { m.createdAt - $0 } ?? Int.max
            if gap > 5 * 60 * 1000 {
                items.append(.divider(id: "ts-\(m.id)", label: Self.timeLabel(m.createdAt)))
            }
            items.append(.message(m))
            prev = m.createdAt
        }
        return items
    }

    /// Reused — allocating a DateFormatter per divider was a real scroll-jank
    /// source on long threads.
    private static let timeFormatter = DateFormatter()
    /// Compact a token count, e.g. 84_000 → "84k", 200_000 → "200k", 950 → "950".
    static func compactTokens(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            // Drop the decimal for whole-thousands; one place otherwise (e.g. 1.2k).
            if k == k.rounded() { return "\(Int(k))k" }
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    static func timeLabel(_ ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        let f = timeFormatter
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(date) { f.dateFormat = "'昨天' HH:mm" }
        else { f.dateFormat = "MM-dd HH:mm" }
        return f.string(from: date)
    }
}
