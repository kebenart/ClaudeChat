import ChatKit
import SwiftUI
import Foundation

// MARK: - PastedText
//
// A large pasted text blob held as a composer attachment rather than inline in
// the text field (huge strings freeze SwiftUI text layout). Shown as a chip;
// its full content is prepended to the prompt on send.
public struct PastedText: Identifiable, Hashable, Sendable {
    public let id: String
    public let content: String
    public var charCount: Int { content.count }

    public init(content: String) {
        self.id = UUID().uuidString
        self.content = content
    }
}

// MARK: - AppViewModel
// (AuthState now lives in the ChatKit core — see Sources/ChatKit/AuthState.swift)

@Observable
@MainActor
public final class AppViewModel {
    // MARK: Auth

    public var authState: AuthState = .bootstrapping
    public var loginError: String?
    public var isLoggingIn = false

    // MARK: Connection health

    /// 3-state connection health (online / reconnecting / offline) surfaced in
    /// the 我 sidebar and via a transient banner. `isConnected` is derived.
    public var connectionState: ConnectionState = .reconnecting(attempt: 0)
    /// Derived: true only when the socket is connected + heartbeat-healthy.
    public var isConnected = false
    /// Last ping→pong round-trip latency in ms; nil until first sample / offline.
    public var latencyMs: Int? = nil
    /// Transient edge banner shown on drop/restore; auto-hides after ~3s.
    public var connectionBanner: String? = nil
    private var wasOnline = false

    // MARK: Server profile

    public var currentServerProfile: ServerProfile?

    // MARK: TOTP setup

    /// Cached artifacts from POST /api/auth/totp/setup. Cleared after
    /// successful verification or when the user skips setup.
    private(set) var totpSetupArtifacts: (uri: String, secret: String, recovery: String)?

    /// Rotated recovery code returned by `/api/auth/login/totp` when the user
    /// signed in with a recovery code. The server invalidates the old code and
    /// returns a fresh one — if we don't surface it the user is silently
    /// locked out of recovery. MainWindowView watches this and shows a sheet
    /// the user must dismiss after copying.
    public var pendingRotatedRecoveryCode: String?

    /// Which Me-tab row the user has selected. `nil` = show the default
    /// landing card. Drives MainWindowView's right-pane content when on the
    /// `.me` rail tab.
    public var selectedMeRole: MeRole? = nil

    // MARK: Sessions

    public var sessions: [SessionInfo] = []
    public var currentSessionId: String?

    /// Conversation ids the server reports as live/active (drives the green online
    /// dot). Derived from the provider session list, which still loads on connect.
    public var liveSessionIds: Set<String> {
        Set(sessions.filter { $0.isActive == true }.map(\.id))
    }

    // MARK: Unread counts keyed by sessionId

    public var unreadCounts: [String: Int] = [:]

    /// Server-synced blacklisted project paths (mirror of /api/im/blacklist).
    /// Sessions whose projectPath equals or nests under one of these are hidden
    /// on every device. Kept in AppViewModel (not the list VM) so it survives a
    /// list rebuild and is reachable from both the sidebar and settings.
    public var blacklistedPaths: Set<String> = []

    /// Bumped whenever any synced conversation meta (pin/mute/note/fold/blacklist)
    /// changes. The sidebar keys its derivation `.task(id:)` on this so fold and
    /// blacklist toggles — which change neither session count nor unread — still
    /// force a re-render.
    public var metaRevision: Int = 0

    // MARK: IM controller (optional — set after init by wireIM())

    /// Owns ImSyncEngine + IM unread. Set once by wireIM(storage:) from the
    /// app entry point where the concrete Storage type is available.
    public var imController: IMController?

    /// Monotonic counter bumped whenever any message is upserted / streamed /
    /// finalized. UI uses `.onChange(of: vm.messageBumpCount)` to refresh
    /// ChatViewModel without round-tripping through @Observable on storage.
    public var messageBumpCount: Int = 0

    /// Sessions where Claude is actively processing a `claude-command` (between
    /// send and `complete` / `error`). ChatView reads this to show
    /// "正在输入中..." under the session nickname.
    public var thinkingSessionIds: Set<String> = []

    /// Reply message ids we've already raised a system notification for, so the
    /// same im:message frame (re-broadcast on every streaming content edit) only
    /// notifies once. Capped to avoid unbounded growth.
    private var notifiedReplyIds: Set<String> = []

    /// Per-conversation live turn progress from im:status frames: (toolCount,
    /// currentTool). Cleared at turn end. Drives the richer typing line
    /// "正在输入… · 执行了 N 个操作 · 正在运行 Bash".
    public var turnProgress: [String: (toolCount: Int, currentTool: String?)] = [:]

    /// A per-conversation progress line. nil when no tools have run yet (the
    /// caller shows a bare "正在输入中…").
    public func progressLine(for id: String) -> String? {
        guard let p = turnProgress[id], p.toolCount > 0 else { return nil }
        return "执行了 \(p.toolCount) 个操作" + (p.currentTool.map { " · 正在运行 \($0)" } ?? "")
    }

    /// Sessions currently backfilling history from the server. ChatView shows
    /// the loading state until the backfill completes, even when the local
    /// cache is empty.
    public var backfillingSessionIds: Set<String> = []

    /// Per-session composer drafts. Persisted in memory only — typing in
    /// session A then switching to B keeps both drafts separate.
    public var composerDrafts: [String: String] = [:]

    /// Per-session pending quote (set by tapping "引用" on a bubble). Travels
    /// as a `> {quote}\n\n` prefix on the next `claude-command`.
    public var composerQuotes: [String: String] = [:]

    /// Per-session pending image attachments (drag-dropped onto the chat view).
    /// Shown as preview chips above the composer; sent with the next prompt.
    public var composerAttachments: [String: [PendingImage]] = [:]

    /// Per-session pending file references (drag-dropped non-image files).
    /// Inserted as `@/absolute/path` lines into the prompt when sending —
    /// Claude Code's CLI accepts `@path` references and will Read them.
    public var composerFilePaths: [String: [String]] = [:]

    /// Per-session pending large pasted-text attachments. When a paste exceeds
    /// the composer threshold we DON'T put it in the text field (90k chars freeze
    /// SwiftUI text layout) — instead we stash the full text here and show a
    /// chip. The full text is prepended to the prompt on send.
    public var composerTextAttachments: [String: [PastedText]] = [:]

    /// Server-side pagination hint per session, captured during the initial
    /// backfill (`/messages?limit=200&offset=0`). ChatViewModel reads this on
    /// load so the "加载更早" button knows whether older messages exist on the
    /// server beyond the local cache.
    public var sessionPagination: [String: (hasMore: Bool, total: Int)] = [:]

    /// Last server-error message (from a WS `kind:'error'` frame). Used by
    /// `createSession` to surface backend-side reasons instead of a generic
    /// timeout message.
    public var lastServerError: String?
    /// Specific error message emitted by `createSession` so the popover can
    /// display the actual reason (server error / WS not connected / etc.).
    public var lastCreateSessionError: String?

    // MARK: Dependencies (injected)

    public let apiClient: any APIClientProtocol
    let socket: any ChatSocketProtocol
    let storage: any StorageProtocol
    let keychain: any KeychainStoreProtocol
    let serverProfileStore: any ServerProfileStoreProtocol

    public init(
        apiClient: some APIClientProtocol,
        socket: some ChatSocketProtocol,
        storage: some StorageProtocol,
        keychain: some KeychainStoreProtocol,
        serverProfileStore: some ServerProfileStoreProtocol
    ) {
        self.apiClient = apiClient
        self.socket = socket
        self.storage = storage
        self.keychain = keychain
        self.serverProfileStore = serverProfileStore

        // Pick up the last used server profile
        self.currentServerProfile = serverProfileStore.mostRecent()
    }

    // MARK: - Auth

    public func login(username: String, password: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            if let profile = currentServerProfile {
                await apiClient.setBaseURL(profile.url)
            }
            let resp = try await apiClient.login(username: username, password: password)
            if let token = resp.token, let user = resp.user {
                if let profile = currentServerProfile {
                    keychain.setToken(token, for: profile.id)
                    await apiClient.setToken(token)
                }
                // If the user has never enrolled TOTP, send them through the setup
                // flow before letting them into the main UI.
                if user.totpEnabled == false {
                    authState = .totpSetupRequired(user: user)
                } else {
                    authState = .loggedIn(user: user)
                    await connectAndLoad()
                }
            } else if resp.requiresTotp == true, let totpToken = resp.totpToken {
                authState = .totpRequired(totpToken: totpToken)
            } else {
                loginError = "登录失败: 服务端返回了未知响应"
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    public func submitTOTP(totpToken: String, code: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            let resp = try await apiClient.loginWithTOTP(totpToken: totpToken, code: code)
            guard let token = resp.token else {
                loginError = "TOTP 验证失败: 服务端未返回 token"
                return
            }
            // If the user authenticated with a recovery code, the server rotated
            // it and returned the replacement in `newRecoveryCode`. Stash it so
            // MainWindowView can prompt the user to save the new code.
            if let rotated = resp.newRecoveryCode, !rotated.isEmpty {
                pendingRotatedRecoveryCode = rotated
            }
            // Persist token + inject into APIClient FIRST so the next call is authenticated.
            if let profile = currentServerProfile {
                keychain.setToken(token, for: profile.id)
            }
            await apiClient.setToken(token)

            // POST /api/auth/login/totp returns only { token } — fetch the user separately.
            let user: User
            if let respUser = resp.user {
                user = respUser
            } else {
                user = try await apiClient.currentUser()
            }
            authState = .loggedIn(user: user)
            await connectAndLoad()
        } catch {
            loginError = error.localizedDescription
        }
    }

    public func logout() async {
        do { try await apiClient.logout() } catch {}
        if let profile = currentServerProfile {
            keychain.setToken(nil, for: profile.id)
        }
        await apiClient.setToken(nil)
        await socket.disconnect()
        authState = .loggedOut
        sessions = []
        currentSessionId = nil
        unreadCounts = [:]
        imController?.stop()
        // Clear per-session client state so a different user logging into the
        // same app doesn't see the previous user's drafts / quotes / etc.
        composerDrafts = [:]
        composerQuotes = [:]
        composerAttachments = [:]
        composerFilePaths = [:]
        composerTextAttachments = [:]
        thinkingSessionIds = []
        backfillingSessionIds = []
        selectedMeRole = nil
        pendingRotatedRecoveryCode = nil
        lastServerError = nil
        lastCreateSessionError = nil
    }

    /// Look up whether a session is currently muted. Returns false for
    /// unknown ids so a stale state doesn't accidentally suppress notifications
    /// for the session we *do* want notifications from.
    private func isSessionMuted(_ sessionId: String) -> Bool {
        sessions.first(where: { $0.id == sessionId })?.isMuted == true
    }

    /// Raise a system notification for an assistant reply that arrived via an
    /// IM hub `im:message` frame (terminal / other device / background turn),
    /// which the SDK `.complete` path doesn't cover. Filters: assistant role +
    /// terminal kind, not the in-focus chat, not a muted IM conversation, and
    /// de-duped by message id (the frame re-broadcasts on every streaming edit).
    private func notifyIMReplyIfNeeded(conversationId: String, message: ImMessageDTO) async {
        guard message.role == "assistant" else { return }
        // Only the settled reply kinds — never streaming text / tool noise.
        let terminalKinds: Set<String> = ["result", "error", "choice", "image"]
        guard terminalKinds.contains(message.kind) else { return }
        // The chat the user is looking at shouldn't buzz.
        guard conversationId != currentSessionId else { return }
        // De-dupe: the same reply is re-broadcast as it streams; notify once.
        guard !notifiedReplyIds.contains(message.id) else { return }
        // Respect the IM conversation's mute flag.
        let conv = imController?.conversations.first { $0.id == conversationId }
        if conv?.isMuted == true { return }
        // Keep the notification in lock-step with the sidebar red dot: if ANY
        // device has already read up to (or past) this reply's seq, the badge
        // wouldn't show, so we must not buzz either. (The badge uses the max read
        // cursor across all devices — read it on the phone and the Mac goes quiet.)
        if let im = imController {
            let maxRead = await im.maxReadSeq(conversationId: conversationId)
            if message.seq <= maxRead { return }
        }

        notifiedReplyIds.insert(message.id)
        if notifiedReplyIds.count > 1000 { notifiedReplyIds.removeAll() } // cap

        let note = conv?.note, hasNote = !(note?.isEmpty ?? true)
        let convTitle = conv?.title, hasTitle = !(convTitle?.isEmpty ?? true)
        let title = hasNote ? note! : (hasTitle ? convTitle! : String(conversationId.prefix(8)))
        let preview = message.kind == "choice" ? "[选择卡片]"
            : message.kind == "image" ? "[图片]"
            : String(message.content.prefix(80))
        SystemNotifications.notifyClaudeReplied(sessionTitle: title, preview: preview)
    }

    // MARK: - TOTP First-time Setup

    /// Called when `TOTPSetupView` appears. Fetches a fresh secret + QR URI from
    /// the server and caches them so the view can render the QR code.
    public func beginTotpSetup() async {
        do {
            let (secret, uri, recovery) = try await apiClient.setupTOTP()
            totpSetupArtifacts = (uri: uri, secret: secret, recovery: recovery)
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Verify the 6-digit code against the pending secret, then activate TOTP.
    /// On success: clears artifacts, transitions to `.loggedIn`.
    public func verifyTotpSetup(code: String) async {
        guard let artifacts = totpSetupArtifacts else {
            loginError = "尚未获取到 TOTP 设置信息,请重试"
            return
        }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            try await apiClient.verifyTOTPSetup(
                secret: artifacts.secret,
                code: code,
                recoveryCode: artifacts.recovery
            )
            totpSetupArtifacts = nil
            // Extract the user from the current auth state so we can transition.
            if case let .totpSetupRequired(user) = authState {
                authState = .loggedIn(user: User(id: user.id,
                                                  username: user.username,
                                                  totpEnabled: true))
                await connectAndLoad()
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Skip TOTP enrollment for this session and proceed to the main UI.
    public func skipTotpSetup() {
        totpSetupArtifacts = nil
        if case let .totpSetupRequired(user) = authState {
            authState = .loggedIn(user: user)
            Task { await connectAndLoad() }
        }
    }

    // MARK: - Usage / context (read-only displays)

    /// Best-effort fetch of the server's Claude usage limits (5h / 7d). Returns
    /// nil on any error so the caller can quietly show "暂无数据".
    /// Best-effort fetch of an assistant-sent image's bytes (kind:'image').
    /// `thumb` requests the small thumbnail (used by the chat bubble).
    public func loadMedia(mediaId: String, thumb: Bool = false) async -> Data? {
        do {
            return try await apiClient.fetchMedia(id: mediaId, thumb: thumb)
        } catch {
            print("[AppViewModel] fetchMedia failed: \(error)")
            return nil
        }
    }

    public func loadUsageLimits(force: Bool = false) async -> ClaudeUsageLimits? {
        do {
            return try await apiClient.fetchClaudeUsageLimits(force: force)
        } catch {
            print("[AppViewModel] fetchClaudeUsageLimits failed: \(error)")
            return nil
        }
    }

    /// Best-effort fetch of a conversation's context-window occupancy. Returns
    /// nil when there's no data yet or on any error.
    public func fetchConversationContext(conversationId: String) async -> ConversationContext? {
        do {
            return try await apiClient.fetchConversationContext(conversationId: conversationId)
        } catch {
            print("[AppViewModel] fetchConversationContext failed: \(error)")
            return nil
        }
    }

    /// Best-effort fetch of a truncated message's full body (server P2 lazy
    /// endpoint). Returns nil on any error → caller falls back to the preview.
    public func fetchMessageContent(conversationId: String, messageId: String) async -> String? {
        do {
            return try await apiClient.fetchMessageContent(conversationId: conversationId, messageId: messageId)
        } catch {
            print("[AppViewModel] fetchMessageContent failed: \(error)")
            return nil
        }
    }

    // MARK: - Sessions

    public func loadSessions() async {
        do {
            let remote = try await apiClient.fetchSessions()
            await storage.upsertSessions(remote)
        } catch {}
        let stored = await storage.listSessions(includingHidden: false)
        sessions = stored
    }

    public func selectSession(_ sessionId: String) async {
        currentSessionId = sessionId
        // Clear provider-side unread when entering the session
        unreadCounts[sessionId] = 0
        await storage.clearUnread(sessionId: sessionId)
        // Clear IM unread and broadcast im:read to all devices.
        imController?.markRead(conversationId: sessionId, apiClient: apiClient)

        // Cache-first for instant switching, but ALWAYS refresh in the background
        // so re-opening a session shows messages added since last open — e.g. a
        // reply from another device, the web, or an auto-running session. Without
        // this the macOS chat (which reads provider messages, not the live IM
        // hub) just shows whatever was cached on first open.
        let cached = await storage.messages(sessionId: sessionId)
        guard cached.isEmpty else {
            Task { await refreshCurrentSessionMessages() }
            return
        }

        // Mark this session as backfilling so ChatView shows a loading spinner
        // rather than the new-session empty state while we wait for the server.
        backfillingSessionIds.insert(sessionId)
        defer { backfillingSessionIds.remove(sessionId) }

        do {
            let page = try await apiClient.fetchMessagesPage(
                sessionId: sessionId,
                limit: 200,
                offset: 0
            )
            for msg in page.messages {
                await storage.upsertMessage(msg)
            }
            sessionPagination[sessionId] = (hasMore: page.hasMore, total: page.total)
            // Bump so ChatView refreshes the now-populated cache.
            messageBumpCount += 1
        } catch {
            // Best-effort: keep empty cache; UI will show the new-session empty state.
        }
    }

    /// Force-refresh history for the currently selected session by pulling from
    /// the server. Bound to a pull-to-refresh / explicit "重新加载" gesture.
    public func refreshCurrentSessionMessages() async {
        guard let sid = currentSessionId else { return }
        do {
            let page = try await apiClient.fetchMessagesPage(
                sessionId: sid,
                limit: 200,
                offset: 0
            )
            for msg in page.messages {
                await storage.upsertMessage(msg)
            }
            sessionPagination[sid] = (hasMore: page.hasMore, total: page.total)
            messageBumpCount += 1
        } catch {}
    }

    // MARK: - Debounced live refresh

    private var sessionListRefreshScheduled = false
    /// Coalesce a reload of the provider session list — still the source of the
    /// live/active set (online dots) and the contacts grouping.
    private func scheduleSessionListRefresh() {
        guard !sessionListRefreshScheduled else { return }
        sessionListRefreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            sessionListRefreshScheduled = false
            await loadSessions()
        }
    }

    public func softDeleteSession(_ sessionId: String) async {
        await storage.setHidden(sessionId: sessionId, hidden: true)
        sessions = await storage.listSessions(includingHidden: false)
        if currentSessionId == sessionId {
            currentSessionId = sessions.first?.id
        }
    }

    public func restoreSession(_ sessionId: String) async {
        await storage.setHidden(sessionId: sessionId, hidden: false)
        sessions = await storage.listSessions(includingHidden: false)
    }

    // MARK: - Transcript (完整记录)

    /// Fetch a page of the raw transcript. No anchor → latest page; with an
    /// anchor (an entry id) → older entries before it. Both walk backwards to
    /// match the server's newest-first contract. Returns an empty page on error.
    public func fetchTranscript(conversationId: String, anchor: String? = nil) async -> ImTranscriptPage {
        do {
            return try await apiClient.fetchImTranscript(
                conversationId: conversationId, anchor: anchor, numBefore: 40, numAfter: 0
            )
        } catch {
            NSLog("[AppViewModel] fetchTranscript failed: \(error)")
            let emptyJSON = #"{"entries":[],"hasMoreBefore":false,"hasMoreAfter":false}"#
            return (try? JSONDecoder().decode(ImTranscriptPage.self, from: Data(emptyJSON.utf8)))!
        }
    }

    // MARK: - Messaging

    public func sendMessage(text: String, projectPath: String?) async {
        let trimmedUser = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return }
        guard let sid = currentSessionId else { return }

        // Pull pending attachments / quote / file refs for this session and
        // clear them now — they ride along with this single send and should
        // not stick around for the next message.
        let images = composerAttachments[sid] ?? []
        let filePaths = composerFilePaths[sid] ?? []
        let quote = composerQuotes[sid]
        composerAttachments[sid] = nil
        composerFilePaths[sid] = nil
        composerQuotes[sid] = nil

        // Compose the prompt: quote as a blockquote prefix, then optional file
        // refs as `@path` lines, then the user's text. The local bubble shows
        // the same final prompt so the user sees what was actually sent.
        var finalPrompt = ""
        if let quote, !quote.isEmpty {
            let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")
            finalPrompt += quoted + "\n\n"
        }
        for p in filePaths { finalPrompt += "@" + p + "\n" }
        finalPrompt += trimmedUser

        let msgId = "user-\(sid)-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"

        // 1) Optimistic local insert so the user sees their own message instantly.
        let msg = ChatMessage(
            id: msgId,
            sessionId: sid,
            role: .user,
            content: finalPrompt,
            createdAt: Date(),
            sendStatus: .sending
        )
        await storage.upsertMessage(msg)
        messageBumpCount += 1
        thinkingSessionIds.insert(sid)

        // 2) Send to server.
        do {
            let event = ClientEvent.claudeCommand(
                prompt: finalPrompt,
                sessionId: currentSessionId,
                projectPath: projectPath,
                modelId: nil,
                resume: currentSessionId != nil,
                // IM sessions auto-approve everything — no tool-approval prompts.
                permissionMode: .bypassPermissions,
                images: images.isEmpty ? nil : images
            )
            let wsConnected = await socket.isConnected
            NSLog("[AppViewModel] sendMessage: sid=\(sid) socket.isConnected=\(wsConnected) projectPath=\(projectPath ?? "nil") resume=\(currentSessionId != nil)")
            try await socket.send(event)
            await storage.setSendStatus(messageId: msgId, .sent)
            messageBumpCount += 1
            NSLog("[AppViewModel] sendMessage: send OK")
            // NOTE: no timeout. The web client doesn't have one either — it
            // just shows "Claude is processing" until a `.complete` arrives.
            // A 60-180s timer was marking real successful sends as failed
            // whenever Claude took longer than that on big tool runs.
        } catch {
            let reason = "网络错误,消息未送达: \(error.localizedDescription)"
            NSLog("[AppViewModel] sendMessage: FAILED — \(reason)")
            await storage.setSendFailure(messageId: msgId, reason: reason)
            messageBumpCount += 1
            thinkingSessionIds.remove(sid)
        }
    }

    /// IM-hub send (Stage 3/4): mirror iOS — a plain claude-command (resume,
    /// bypass permissions). The optimistic echo lives in ImChatViewModel.pending;
    /// the reply arrives as an im:message the IM chat reloads on. No provider
    /// ChatMessage is written.
    /// Returns true if the send reached the socket, false if it threw (so the
    /// chat can flag the optimistic bubble as failed → red "!" + tap-to-resend).
    @discardableResult
    public func sendIM(text: String, conversationId: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let conv = imController?.conversations.first { $0.id == conversationId }
        let event = ClientEvent.claudeCommand(
            prompt: trimmed,
            sessionId: conversationId,
            projectPath: conv?.contactId,
            modelId: nil,
            resume: true,
            permissionMode: .bypassPermissions
        )
        thinkingSessionIds.insert(conversationId)
        do {
            try await socket.send(event)
            return true
        } catch {
            NSLog("[AppViewModel] sendIM failed: \(error.localizedDescription)")
            thinkingSessionIds.remove(conversationId)
            return false
        }
    }

    // MARK: - Quote / attachment / mute helpers

    public func setQuote(sessionId: String, _ quote: String?) {
        if let quote, !quote.isEmpty {
            composerQuotes[sessionId] = quote
        } else {
            composerQuotes[sessionId] = nil
        }
    }

    public func addImage(sessionId: String, _ image: PendingImage) {
        var arr = composerAttachments[sessionId] ?? []
        arr.append(image)
        composerAttachments[sessionId] = arr
    }

    public func removeImage(sessionId: String, id: String) {
        composerAttachments[sessionId] = (composerAttachments[sessionId] ?? []).filter { $0.id != id }
        if composerAttachments[sessionId]?.isEmpty == true {
            composerAttachments[sessionId] = nil
        }
    }

    public func addFilePath(sessionId: String, _ path: String) {
        var arr = composerFilePaths[sessionId] ?? []
        if !arr.contains(path) { arr.append(path) }
        composerFilePaths[sessionId] = arr
    }

    public func removeFilePath(sessionId: String, _ path: String) {
        composerFilePaths[sessionId] = (composerFilePaths[sessionId] ?? []).filter { $0 != path }
        if composerFilePaths[sessionId]?.isEmpty == true {
            composerFilePaths[sessionId] = nil
        }
    }

    public func addTextAttachment(sessionId: String, _ text: String) {
        var arr = composerTextAttachments[sessionId] ?? []
        arr.append(PastedText(content: text))
        composerTextAttachments[sessionId] = arr
    }

    public func removeTextAttachment(sessionId: String, id: String) {
        composerTextAttachments[sessionId] = (composerTextAttachments[sessionId] ?? []).filter { $0.id != id }
        if composerTextAttachments[sessionId]?.isEmpty == true {
            composerTextAttachments[sessionId] = nil
        }
    }

    // MARK: - Toast + manual refresh

    /// Transient toast surfaced when a server mutation fails; the UI shows it
    /// briefly and clears it. Mirrors the iOS toast.
    public var toast: ToastMessage?
    public struct ToastMessage: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
    }
    private func showToast(_ text: String) { toast = ToastMessage(text: text) }
    /// Run a server mutation; on failure surface a toast. The optimistic local
    /// change already applied (and deletes also re-assert on launch).
    private func pushOrToast(_ failHint: String, _ work: () async throws -> Void) async {
        do { try await work() } catch { showToast(failHint) }
    }

    /// Manual refresh (sidebar refresh button): re-pull provider sessions + the
    /// IM /sync from the current cursor.
    public func manualRefresh() async {
        await loadSessions()
        await imController?.resync(apiClient: apiClient)
    }

    public func setMuted(sessionId: String, _ muted: Bool) async {
        await storage.setMuted(sessionId: sessionId, muted)
        await optimisticImState(sessionId) { $0.with(isMuted: muted) }
        await pushOrToast("免打扰未同步,请检查网络") {
            try await apiClient.postImState(conversationId: sessionId,
                                            isPinned: nil, isMuted: muted, isFolded: nil, isDeleted: nil, note: nil)
        }
        sessions = await storage.listSessions(includingHidden: false)
        metaRevision += 1
    }

    public func setPinned(sessionId: String, _ pinned: Bool) async {
        await storage.setPinned(sessionId: sessionId, pinned)
        await optimisticImState(sessionId) { $0.with(isPinned: pinned) }
        await pushOrToast("置顶未同步,请检查网络") {
            try await apiClient.postImState(conversationId: sessionId,
                                            isPinned: pinned, isMuted: nil, isFolded: nil, isDeleted: nil, note: nil)
        }
        sessions = await storage.listSessions(includingHidden: false)
        metaRevision += 1
    }

    /// Set / clear a session's note (备注名). Persists locally AND to the IM hub
    /// so the nickname follows the user across devices.
    public func setNote(sessionId: String, _ note: String?) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        await storage.setNote(sessionId: sessionId, value)
        await optimisticImState(sessionId) { $0.with(note: .some(value)) }
        await pushOrToast("备注未同步,请检查网络") {
            try await apiClient.postImState(conversationId: sessionId,
                                            isPinned: nil, isMuted: nil, isFolded: nil, isDeleted: nil, note: .some(value))
        }
        sessions = await storage.listSessions(includingHidden: false)
        metaRevision += 1
    }

    /// Fold / unfold a session ("折叠的聊天"). Fold lives only on the IM hub
    /// (no local SessionRecord column), so we update the local IM conversation
    /// optimistically and push to the server.
    public func setFolded(sessionId: String, _ folded: Bool) async {
        await optimisticImState(sessionId) { $0.with(isFolded: folded) }
        await pushOrToast("折叠未同步,请检查网络") {
            try await apiClient.postImState(conversationId: sessionId,
                                            isPinned: nil, isMuted: nil, isFolded: folded, isDeleted: nil, note: nil)
        }
        // Nudge the sidebar to re-derive fold state from storage.
        sessions = await storage.listSessions(includingHidden: false)
        metaRevision += 1
    }

    /// Delete a conversation (WeChat-style), server-synced so it disappears on
    /// every device. Soft on the hub: a later inbound message resurrects it.
    /// Also hides the local SessionRecord so it vanishes immediately even for a
    /// session that isn't in the IM hub yet.
    public func deleteConversation(sessionId: String) async {
        // Persisted guard + launch re-assert, so the delete survives a restart even
        // if the /state POST below is lost (mirrors the iOS durable-delete fix).
        imController?.markLocallyDeleted(sessionId, true)
        await optimisticImState(sessionId) { $0.with(isDeleted: true) }
        await storage.setHidden(sessionId: sessionId, hidden: true)
        await pushOrToast("删除未同步,启动时会自动重试") {
            try await apiClient.postImState(conversationId: sessionId,
                                            isPinned: nil, isMuted: nil, isFolded: nil, isDeleted: true, note: nil)
        }
        sessions = await storage.listSessions(includingHidden: false)
        if currentSessionId == sessionId { currentSessionId = sessions.first?.id }
        metaRevision += 1
    }

    /// Apply an optimistic local edit to the IM conversation row so the sidebar
    /// (which overlays IM-hub state onto each session) reflects the change before
    /// the server round-trips an im:poke back. No-op if the conversation hasn't
    /// been synced into the hub yet — the local SessionRecord still carries
    /// pin/mute/note in that case.
    private func optimisticImState(_ sessionId: String,
                                   _ transform: (ImConversationDTO) -> ImConversationDTO) async {
        let convs = await storage.imConversations()
        guard let conv = convs.first(where: { $0.id == sessionId }) else { return }
        await storage.upsertImConversation(transform(conv))
        // Re-publish the IM list NOW so the sidebar reflects the edit (esp. a
        // delete vanishing) immediately, instead of only after switching tabs.
        await imController?.refreshNow()
    }

    // MARK: - Blacklist (server-synced)

    public func isPathBlacklisted(_ path: String?) -> Bool {
        guard let p = path, !p.isEmpty else { return false }
        return blacklistedPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Pull the authoritative blacklist from the server. Best-effort: a network
    /// failure leaves the current set untouched.
    public func refreshBlacklist() async {
        if let paths = try? await apiClient.fetchBlacklist() {
            blacklistedPaths = Set(paths)
            metaRevision += 1
        }
    }

    public func setBlacklisted(_ path: String, _ blacklisted: Bool) async {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        // Optimistic local update so the row disappears immediately.
        if blacklisted { blacklistedPaths.insert(p) } else { blacklistedPaths.remove(p) }
        metaRevision += 1
        if blacklisted {
            try? await apiClient.addBlacklist(path: p)
        } else {
            try? await apiClient.removeBlacklist(path: p)
        }
    }

    public func markRead(sessionId: String) async {
        await storage.clearUnread(sessionId: sessionId)
        unreadCounts[sessionId] = 0
        // Also mark the IM conversation as read and broadcast im:read cross-device.
        imController?.markRead(conversationId: sessionId, apiClient: apiClient)
    }

    /// Any incoming WS event for `sessionId` proves Claude received the user
    /// message — flip any pending `.sending` / `.sent` to `.delivered`. We do
    /// NOT flip `.failed` clean here: real prior failures must remain visible
    /// (a later successful turn does not erase an earlier rejected one).
    private func clearStaleFailures(for sessionId: String) async {
        await storage.markUserMessagesDelivered(sessionId: sessionId)
    }

    /// Send an abort frame to the server for the given session. The SDK
    /// stops the in-flight `query()` for that session id; the server then
    /// emits a `complete` event with `aborted: true`. We also flip the
    /// local thinking state immediately so the UI doesn't lag the abort.
    public func abortSession(_ sessionId: String) async {
        do {
            try await socket.send(.abortSession(sessionId: sessionId))
            thinkingSessionIds.remove(sessionId)
        } catch {
            // Even if the abort frame fails to send, clear local state so the
            // user isn't stuck staring at "正在输入中…".
            thinkingSessionIds.remove(sessionId)
            NSLog("[AppViewModel] abortSession: failed to send: \(error)")
        }
    }

    public func respondToToolApproval(requestId: String, allow: Bool, updatedInput: String? = nil) async {
        do {
            try await socket.send(.toolApprovalResponse(requestId: requestId, allow: allow, updatedInput: updatedInput))
        } catch {}
    }

    /// Answer an interactive choice card (红包-style poll) over the chat WS.
    /// `answers` for AskUserQuestion, `approve` for ExitPlanMode. The server flips
    /// the card to answered and it re-syncs into the thread. Returns true on send.
    @discardableResult
    public func respondChoice(conversationId: String, requestId: String,
                              answers: [String: [String]]?, approve: Bool?) async -> Bool {
        do {
            try await socket.send(.imChoiceAnswer(requestId: requestId, answers: answers, approve: approve))
            return true
        } catch {
            NSLog("[AppViewModel] respondChoice failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - New session creation

    /// Send a `claudeCommand` to start a new session and return the sessionId once
    /// the server emits `session_created`.
    ///
    /// Implementation: sends the event over the socket. The server responds with a
    /// `session_created` event which is handled by `handleServerEvent`, setting
    /// `currentSessionId`. We wait up to 5 s for that value to appear by polling
    /// in a detached task, then return it. If no session is created within the
    /// timeout, nil is returned.
    @discardableResult
    public func createSession(projectPath: String, firstPrompt: String) async -> String? {
        lastCreateSessionError = nil
        let previousSessionId = currentSessionId
        let errorBaseline = lastServerError

        // Send the bootstrap claude-command. sessionId is intentionally nil so
        // the SDK allocates a fresh id; the server then emits a
        // `session_created` event which `handleServerEvent` writes into
        // `currentSessionId`.
        do {
            let event = ClientEvent.claudeCommand(
                prompt: firstPrompt,
                sessionId: nil,
                projectPath: projectPath,
                modelId: nil,
                resume: false,
                permissionMode: .bypassPermissions
            )
            try await socket.send(event)
        } catch {
            lastCreateSessionError = "WebSocket 发送失败: \(error.localizedDescription)。请检查后端是否运行,登录态是否过期。"
            return nil
        }

        // Poll for up to 30s — Claude SDK can take 5-15s to spin up on a fresh
        // session because it has to enumerate tools, validate the workspace,
        // etc. 5s was way too tight and gave the false "creation failed".
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            // Success path: the session id flipped.
            if let sid = currentSessionId, sid != previousSessionId {
                return sid
            }
            // Server-side error path: fail fast with the reason.
            if let err = lastServerError, err != errorBaseline {
                lastCreateSessionError = "服务端错误: \(err)"
                return nil
            }
        }
        lastCreateSessionError = "等待超时:30 秒内后端未返回 session_created 事件。可能路径无效、Claude SDK 未启动、或登录态丢失。"
        return nil
    }

    // MARK: - Socket event processing

    /// Self-healing fallback for a stuck "正在输入… · 执行了 N 个操作" row. It
    /// normally clears on the one-shot im:status(false) frame, but that frame is
    /// lost if we're mid-reconnect when a long turn ends — the reply then lands
    /// via /sync (not a live im:status), and the row sticks forever. So whenever
    /// an im:message / im:poke lands, drop progress for any conversation whose
    /// newest stored message is already an assistant reply (no turn in flight).
    /// An active turn re-lights via the next im:status(true). Mirrors watchOS.
    private func clearAnsweredThinking() async {
        guard !thinkingSessionIds.isEmpty || !turnProgress.isEmpty else { return }
        let ids = thinkingSessionIds.union(turnProgress.keys)
        for id in ids {
            // latestMessage = a fetchLimit=1 query; don't load the whole session
            // just to read its last row (that full fetch on every refresh stalled).
            let latest = await storage.latestMessage(sessionId: id)
            if latest?.role == .assistant {
                thinkingSessionIds.remove(id)
                turnProgress[id] = nil
            }
        }
    }

    public func startEventLoop() {
        Task {
            // Mirror ping→pong latency samples onto this @Observable model.
            await socket.setLatencyHandler { [weak self] ms in
                Task { @MainActor in self?.latencyMs = ms }
            }
            for await event in socket.events {
                await handleServerEvent(event)
            }
        }
    }

    /// Fire an immediate ping to refresh `latencyMs` on demand (e.g. from the
    /// 我 sidebar). No-op if the socket isn't connected.
    public func pingNow() async {
        await socket.ping()
    }

    private func handleServerEvent(_ event: ServerEvent) async {
        switch event {
        case let .sessionCreated(sessionId):
            await loadSessions()
            currentSessionId = sessionId

        case let .assistantText(sessionId, messageId, text, isDelta):
            // Defensive: backend frames sent before `session_created` may carry
            // an empty sessionId. Routing those into storage would attach them
            // to a bogus "" session that bleeds into every view. Drop instead.
            guard !sessionId.isEmpty else {
                NSLog("[AppViewModel] dropped assistantText with empty sessionId (pre-session_created)")
                break
            }
            // Claude is responding → any prior user-side .failed in this
            // session was a false-positive timeout. Clear it.
            await clearStaleFailures(for: sessionId)
            if isDelta {
                await storage.appendStreamDelta(messageId: messageId, sessionId: sessionId, delta: text)
            } else {
                let msg = ChatMessage(id: messageId, sessionId: sessionId, role: .assistant,
                                     content: text, isStreaming: true)
                await storage.upsertMessage(msg)
            }
            messageBumpCount += 1

        case let .toolUse(sessionId, messageId, name, input):
            guard !sessionId.isEmpty else {
                NSLog("[AppViewModel] dropped toolUse with empty sessionId (pre-session_created)")
                break
            }
            await clearStaleFailures(for: sessionId)
            let msg = ChatMessage(id: messageId, sessionId: sessionId, role: .tool,
                                  content: "",
                                  toolUse: ToolInvocation(name: name, input: input, requiresApproval: false))
            await storage.upsertMessage(msg)

        case let .toolResult(sessionId, toolUseId, output, _):
            guard !sessionId.isEmpty else {
                NSLog("[AppViewModel] dropped toolResult with empty sessionId (pre-session_created)")
                break
            }
            // finalize the tool message with output
            var msg = ChatMessage(id: toolUseId, sessionId: sessionId, role: .tool,
                                  content: output)
            msg.toolUse = ToolInvocation(name: "", input: "", output: output)
            await storage.upsertMessage(msg)
            messageBumpCount += 1

        case let .permissionRequest(sessionId, requestId, toolName, input, _):
            guard !sessionId.isEmpty else {
                NSLog("[AppViewModel] dropped permissionRequest with empty sessionId")
                break
            }
            let msg = ChatMessage(id: requestId, sessionId: sessionId, role: .tool,
                                  content: "",
                                  toolUse: ToolInvocation(name: toolName, input: input,
                                                          approvalState: .pending,
                                                          requestId: requestId,
                                                          requiresApproval: true))
            await storage.upsertMessage(msg)
            messageBumpCount += 1
            // Notify user that a tool needs manual approval — unless this
            // session is muted, in which case skip notifications entirely.
            if !isSessionMuted(sessionId) {
                let approvalSessionTitle = sessions.first(where: { $0.id == sessionId })?.title
                    ?? sessionId
                await SystemNotifications.notifyToolApprovalNeeded(
                    sessionTitle: approvalSessionTitle,
                    toolName: toolName
                )
            }

        case let .complete(sessionId, _, _, _):
            // Note: finalizeStreaming(messageId: "") below is intentionally a
            // no-op — the actual streaming finalisation is done implicitly by
            // each assistantText event that arrives. We only need this case
            // for the bookkeeping below.
            // Clear "thinking" state regardless of whether this session is in focus.
            thinkingSessionIds.remove(sessionId)
            turnProgress[sessionId] = nil
            // Stop the streaming dots — finalize any still-streaming bubble.
            await storage.finalizeStreaming(sessionId: sessionId)
            // Mark all pending user messages in this session as delivered.
            await storage.markUserMessagesDelivered(sessionId: sessionId)
            if sessionId != currentSessionId {
                await storage.incrementUnread(sessionId: sessionId)
                let curr = unreadCounts[sessionId, default: 0]
                unreadCounts[sessionId] = curr + 1
                // Notify user that Claude replied in a background session —
                // unless the session is muted.
                if !isSessionMuted(sessionId) {
                    let completeSessionTitle = sessions.first(where: { $0.id == sessionId })?.title
                        ?? sessionId
                    await SystemNotifications.notifyClaudeReplied(
                        sessionTitle: completeSessionTitle,
                        preview: ""
                    )
                }
            }
            await loadSessions()
            messageBumpCount += 1

        case let .error(sessionId, message):
            // Stash the most recent server error so flows like createSession()
            // can surface a specific reason instead of a generic timeout.
            lastServerError = message
            let errorSessionTitle: String
            if let sid = sessionId {
                thinkingSessionIds.remove(sid)
                turnProgress[sid] = nil
                await storage.finalizeStreaming(sessionId: sid)
                errorSessionTitle = sessions.first(where: { $0.id == sid })?.title ?? sid
                // Flip the most recent .sending / .sent user message in this
                // session to .failed with the server-supplied error reason.
                if let last = await storage.messages(sessionId: sid)
                    .reversed()
                    .first(where: { $0.role == .user
                                    && ($0.sendStatus == .sent || $0.sendStatus == .sending) }) {
                    await storage.setSendFailure(messageId: last.id,
                                                 reason: "服务端错误: \(message)")
                    messageBumpCount += 1
                }
            } else {
                // Unknown session — clear all thinking flags as a safety net.
                thinkingSessionIds.removeAll()
                turnProgress.removeAll()
                errorSessionTitle = "Unknown session"
            }
            await SystemNotifications.notifyClaudeError(
                sessionTitle: errorSessionTitle,
                message: message
            )

        case let .imMessage(conversationId, message):
            // Route IM hub frames to the IM controller, which folds them into
            // storage and bumps syncRevision — the IM chat (ImChatView) reloads
            // on that. No provider re-fetch needed.
            imController?.applyFrame(event, apiClient: apiClient)
            // The reply that ends a turn arrives here — clear any stuck progress
            // row even if the terminal im:status(false) was missed.
            await clearAnsweredThinking()
            // Notify on an assistant reply that landed via the IM hub (terminal /
            // another device / a background SDK turn). Previously ONLY the SDK
            // `.complete` path notified, so card/普通 messages arriving as
            // im:message frames were silent. Mirror iOS: assistant reply, terminal
            // kind (result/error/choice/image), not the in-focus chat, not muted,
            // de-duped by message id (the frame re-broadcasts on each edit).
            await notifyIMReplyIfNeeded(conversationId: conversationId, message: message)

        case .imRead:
            imController?.applyFrame(event, apiClient: apiClient)

        case .imPoke:
            imController?.applyFrame(event, apiClient: apiClient)
            // A poke means something changed server-side (new messages, meta);
            // refresh the provider session list so the sidebar previews/order
            // aren't stuck on stale data. Debounced.
            scheduleSessionListRefresh()
            // Reply may have landed via the sync the poke triggers — clear stuck rows.
            await clearAnsweredThinking()

        case let .imStatus(conversationId, isProcessing, toolCount, currentTool):
            // Richer turn progress than complete/sessionStatus: tool count +
            // currently-running tool, throttled by the server.
            if isProcessing {
                thinkingSessionIds.insert(conversationId)
                turnProgress[conversationId] = (toolCount, currentTool)
            } else {
                thinkingSessionIds.remove(conversationId)
                turnProgress[conversationId] = nil
            }

        case let .connection(state):
            connectionState = state
            isConnected = (state == .online)
            // A non-online link has no meaningful latency — clear the stale value.
            if state != .online { latencyMs = nil }
            handleConnectionTransition(to: state)

        default:
            break
        }
    }

    // MARK: - Connection health (transient banner)

    private func handleConnectionTransition(to state: ConnectionState) {
        switch state {
        case .online:
            if wasOnline { showConnectionBanner("已重新连接") }   // edge: restored
            wasOnline = true
        case .reconnecting:
            if wasOnline { showConnectionBanner("连接断开，正在重连…") }
        case .offline:
            if wasOnline { showConnectionBanner("网络已断开") }
        case .failed:
            showConnectionBanner("连接失败 · 请手动重连")
        }
    }

    private func showConnectionBanner(_ text: String) {
        connectionBanner = text
        let token = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if self.connectionBanner == token { self.connectionBanner = nil }
        }
    }

    // MARK: - Convenience

    public var currentUser: User? {
        switch authState {
        case .loggedIn(let user): return user
        case .totpSetupRequired(let user): return user
        default: return nil
        }
    }

    /// Single source of truth for *my* avatar — used by the 我 sidebar AND the
    /// outgoing chat bubbles so they always match (and match iOS/web, which key
    /// on the username too).
    public var myAvatarSeed: String { currentUser.map { "user-\($0.username)" } ?? "me" }
    public var myDisplayName: String { currentUser?.username ?? "未登录" }

    public var totalUnread: Int {
        mergedUnreadCounts.values.reduce(0, +)
    }

    /// Merged unread counts: max of provider-side unreadCounts and IM-side
    /// unreadByConversation for each session id. This is the value the sidebar
    /// should read so the badge reflects whichever source has the higher count.
    public var mergedUnreadCounts: [String: Int] {
        var merged = unreadCounts
        if let im = imController?.unreadByConversation {
            for (id, count) in im {
                merged[id] = max(merged[id, default: 0], count)
            }
        }
        return merged
    }

    // MARK: - Internal helpers

    /// Build the WebSocket URL from the HTTP base URL.
    /// `http://host:port` → `ws://host:port/ws`
    /// `https://host:port` → `wss://host:port/ws`
    func wsURL(from httpURL: URL) -> URL? {
        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: true)
        switch components?.scheme {
        case "http":  components?.scheme = "ws"
        case "https": components?.scheme = "wss"
        default: break
        }
        let current = components?.path ?? ""
        let trimmed = current.hasSuffix("/") ? String(current.dropLast()) : current
        components?.path = trimmed + "/ws"
        return components?.url
    }

    /// Connect the WebSocket using the current profile token, then start the
    /// event loop and load sessions. Called after a successful login or bootstrap.
    /// In DEV_AUTH_BYPASS mode the token can be empty — server WS upgrade no
    /// longer enforces it.
    func connectAndLoad() async {
        guard let profile = currentServerProfile,
              let wsURL = wsURL(from: profile.url) else {
            NSLog("[AppViewModel] connectAndLoad: no profile / wsURL — falling back to loadSessions only")
            await loadSessions()
            return
        }
        let token = keychain.token(for: profile.id) ?? "dev-bypass"
        NSLog("[AppViewModel] connectAndLoad: connecting WS to \(wsURL.absoluteString) (token=\(token.isEmpty ? "EMPTY" : "len=\(token.count)"))")
        do {
            try await socket.connect(baseURL: wsURL, token: token)
            let connected = await socket.isConnected
            NSLog("[AppViewModel] connectAndLoad: socket.isConnected=\(connected)")
        } catch {
            NSLog("[AppViewModel] connectAndLoad: socket.connect threw: \(error.localizedDescription)")
            // Non-fatal: chat history can still load; reconnect will be attempted
        }
        await loadSessions()
        // Kick off the initial IM sync so unread counts are populated.
        imController?.start(apiClient: apiClient)
        // Pull the server-synced blacklist so hidden project paths match the
        // other devices.
        await refreshBlacklist()
    }

    /// User-triggered reconnect (tapped the "连接失败 · 点击重连" status after the
    /// socket gave up). Goes through connectAndLoad() — the concrete socket resets
    /// its auto-retry counter inside connect(baseURL:token:) — and reloads.
    func manualReconnect() async {
        await connectAndLoad()
    }

    /// Called once at app launch. Detects three states in priority order:
    /// (1) server in DEV_AUTH_BYPASS mode → skip login UI, fetch /api/auth/user;
    /// (2) keychain holds a valid token → silent restore;
    /// (3) otherwise → show login.
    ///
    /// Idempotent: if the sync probe in main.swift already set authState to
    /// `.loggedIn`, we skip the network round-trips and just kick the WS off.
    /// Without this guard a slow network can flip an already-authed user back
    /// to LoginView.
    public func bootstrapAuth() async {
        NSLog("[AppViewModel] bootstrapAuth: entry authState=\(authStateDescription)")
        // Already past bootstrap (sync probe set .loggedIn, or auth flow set
        // .totpRequired/.totpSetupRequired). Just connect WS + load sessions
        // if we haven't yet.
        if case .loggedIn = authState {
            NSLog("[AppViewModel] bootstrapAuth: already .loggedIn — calling connectAndLoad()")
            await connectAndLoad()
            return
        }
        // Anything other than the initial .bootstrapping or .loggedOut state
        // means the user is actively in TOTP flow — don't interfere.
        switch authState {
        case .bootstrapping, .loggedOut:
            break
        case .totpRequired, .totpSetupRequired, .loggedIn:
            NSLog("[AppViewModel] bootstrapAuth: state=\(authStateDescription) — returning")
            return
        }

        if let profile = currentServerProfile {
            await apiClient.setBaseURL(profile.url)
            NSLog("[AppViewModel] bootstrapAuth: setBaseURL=\(profile.url.absoluteString)")
        }
        // (1) Dev bypass — server has DEV_AUTH_BYPASS=1, log in silently.
        if await apiClient.devAuthBypassed() {
            NSLog("[AppViewModel] bootstrapAuth: server reports DEV_AUTH_BYPASS")
            if let user = try? await apiClient.currentUser() {
                authState = .loggedIn(user: user)
                NSLog("[AppViewModel] bootstrapAuth: -> .loggedIn (dev-bypass, user=\(user.username))")
                await connectAndLoad()
                return
            } else {
                NSLog("[AppViewModel] bootstrapAuth: bypass detected but currentUser() failed — continuing")
            }
        }
        // (2) Try cached token.
        if let profile = currentServerProfile,
           let cached = keychain.token(for: profile.id) {
            await apiClient.setToken(cached)
            if let user = try? await apiClient.currentUser() {
                authState = .loggedIn(user: user)
                NSLog("[AppViewModel] bootstrapAuth: -> .loggedIn (cached token, user=\(user.username))")
                await connectAndLoad()
                return
            }
            // Token invalid (server restarted with new secret, expired, etc.) —
            // clear it so we don't loop.
            keychain.setToken(nil, for: profile.id)
            await apiClient.setToken(nil)
            NSLog("[AppViewModel] bootstrapAuth: cached token rejected — cleared")
        }
        // (3) No bypass + no valid cached token → show LoginView.
        authState = .loggedOut
        NSLog("[AppViewModel] bootstrapAuth: -> .loggedOut (no bypass, no cached token)")
    }

    /// Human-readable authState label for log lines.
    private var authStateDescription: String {
        switch authState {
        case .bootstrapping:      return ".bootstrapping"
        case .loggedOut:          return ".loggedOut"
        case .totpRequired:       return ".totpRequired"
        case .totpSetupRequired:  return ".totpSetupRequired"
        case .loggedIn(let u):    return ".loggedIn(\(u.username))"
        }
    }
}
