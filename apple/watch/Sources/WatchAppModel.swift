import Foundation
import Observation
import ChatKit

/// Minimal watch-side app state. Reuses the ChatKit core (APIClient / ChatSocket
/// / Storage / ImSyncEngine) — exactly like the iOS app, but trimmed to the
/// three things the watch needs: list conversations, read one, and send a
/// dictated message. No tools, no settings beyond the server URL.
@MainActor
@Observable
public final class WatchAppModel {
    // MARK: - Public state
    public var conversations: [ImConversationDTO] = []
    public var unread: [String: Int] = [:]
    public var isConnected = false
    /// 3-state connection health (online / reconnecting / offline). On the tiny
    /// watch screen the top status line IS the banner; `isConnected` is derived.
    public var connectionState: ConnectionState = .reconnecting(attempt: 0)
    /// Transient edge banner on drop/restore; auto-hides after ~3s.
    public var connectionBanner: String? = nil
    private var wasOnline = false
    public var isSyncing = false
    public var lastError: String?
    /// Conversations awaiting a reply — drives a small "正在输入…" line.
    public var thinkingIds: Set<String> = []
    /// Per-conversation live turn progress from im:status frames: (toolCount,
    /// currentTool). The watch is REST-only (no chat WS), so this is populated
    /// only if an im:status ever arrives via a future channel; today it stays
    /// empty and the typing line is the bare "正在输入…". Kept for parity.
    public var turnProgress: [String: (toolCount: Int, currentTool: String?)] = [:]

    /// A per-conversation progress line for the typing indicator. nil when no
    /// tools have run yet (caller shows a bare "正在输入…").
    public func progressLine(for id: String) -> String? {
        guard let p = turnProgress[id], p.toolCount > 0 else { return nil }
        return "执行了 \(p.toolCount) 个操作" + (p.currentTool.map { " · 正在运行 \($0)" } ?? "")
    }

    /// Apply an im:status frame (if the watch ever receives one). Mirrors iOS.
    public func applyImStatus(conversationId: String, isProcessing: Bool, toolCount: Int, currentTool: String?) {
        if isProcessing {
            thinkingIds.insert(conversationId)
            turnProgress[conversationId] = (toolCount, currentTool)
        } else {
            thinkingIds.remove(conversationId)
            turnProgress[conversationId] = nil
        }
    }
    /// Just-deleted ids, hidden until the server confirms (matches iOS).
    public private(set) var locallyDeletedIds: Set<String> = []
    /// Server-synced blacklist of project paths (mirror of /api/im/blacklist).
    public var blacklistedPaths: Set<String> = []

    // MARK: - Auth state
    /// True once a valid token is active (login succeeded, restored, or dev-bypass).
    public var isAuthenticated = false
    /// Non-nil while waiting for the user to enter a TOTP code.
    public var pendingTotpToken: String?
    public var isLoggingIn = false
    public var loginError: String?
    /// JWT bearer token, persisted across launches (UserDefaults — watch is a
    /// lower-risk device; the iOS/macOS apps use Keychain).
    public private(set) var token: String? {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }
    private static let tokenKey = "watch_auth_token"

    /// The server the watch talks to directly (over WiFi/LTE). Defaults to the
    /// domain because the watch is remote-only (127.0.0.1 would be the watch
    /// itself). Editable on the setup screen.
    public var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.urlKey) }
    }
    public var isConfigured = false

    private static let urlKey = "watch_server_url"
    private static let defaultURL = "https://cli.example.com:8443"

    // MARK: - Core
    private let storage: Storage
    private let engine: ImSyncEngine
    private let api = APIClient()
    private let deviceId: String
    /// Foreground REST polling. watchOS forbids WebSockets (URLSessionWebSocketTask
    /// fails with "Path was denied by NECP policy" on real devices — Apple TN3135),
    /// so the watch RECEIVES replies by polling /sync and SENDS via a REST endpoint.
    private var pollTask: Task<Void, Never>?
    /// Consecutive failed syncs. After `maxSyncFailures` in a row we stop polling
    /// and surface `.failed` (tap-to-reconnect) instead of spinning offline forever.
    private var syncFailureCount = 0
    private static let maxSyncFailures = 3
    // Adaptive poll cadence (battery): Apple's watchOS energy guidance is to poll
    // only as often as actually needed. Fast only while awaiting a reply; slow
    // when just browsing. Background stops the loop entirely (scenePhase).
    private static let activePollNanos: UInt64 = 4_000_000_000   // ~4s — a reply is pending
    private static let idlePollNanos: UInt64 = 30_000_000_000    // ~30s — idle browsing

    public init() {
        let profile = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let container = (try? StorageContainer.makeOnDisk(profileId: profile))
            ?? (try! StorageContainer.makeInMemory())
        self.storage = Storage(container: container)
        self.engine = ImSyncEngine(storage: storage)
        self.deviceId = DeviceIdentity.current()
        self.serverURLString = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
        self.token = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    // MARK: - Lifecycle

    /// Connect to the server and run the initial sync using the active token
    /// (nil/empty only under DEV_AUTH_BYPASS).
    public func connect() async {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)) else {
            lastError = "服务器地址无效"
            return
        }
        isConfigured = true
        await api.setBaseURL(url)
        await api.setToken(token)
        // Show cached history first (local storage) so opening isn't a full-screen
        // "正在同步" — then the network sync refreshes in place.
        await refresh()
        await pagedSync()
        await refreshBlacklist()
        // REST-only on watchOS: no socket. Poll /sync in the foreground for replies.
        startPolling()
    }

    // MARK: - Auth (password + TOTP)

    /// Launch bootstrap: restore a stored token, else auto-skip only if the
    /// server runs in DEV_AUTH_BYPASS, else require login (show WatchLoginView).
    public func bootstrap() async {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)) else {
            isAuthenticated = false
            return
        }
        await api.setBaseURL(url)
        if let t = token, !t.isEmpty {
            isAuthenticated = true
            await connect()
            return
        }
        // No token — let a DEV_AUTH_BYPASS server through without login.
        if await api.devAuthBypassed() {
            isAuthenticated = true
            await connect()
            return
        }
        isAuthenticated = false   // → WatchLoginView
    }

    /// Password login. Returns `true` if fully authenticated, `false` if it
    /// failed OR a TOTP second factor is now required (check `pendingTotpToken`).
    @discardableResult
    public func login(username: String, password: String) async -> Bool {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)) else {
            loginError = "服务器地址无效"
            return false
        }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        await api.setBaseURL(url)
        do {
            let resp = try await api.login(username: username, password: password)
            if let t = resp.token {
                token = t
                isAuthenticated = true
                await connect()
                return true
            } else if resp.requiresTotp == true, let totp = resp.totpToken {
                pendingTotpToken = totp
                return false
            } else {
                loginError = "登录失败,请检查用户名或密码"
                return false
            }
        } catch {
            loginError = "登录失败,请检查账号或网络"
            return false
        }
    }

    /// Submit the TOTP code after `login` returned `requiresTotp`.
    @discardableResult
    public func submitTOTP(code: String) async -> Bool {
        guard let totp = pendingTotpToken else { return false }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            let resp = try await api.loginWithTOTP(totpToken: totp, code: code)
            if let t = resp.token {
                token = t
                pendingTotpToken = nil
                isAuthenticated = true
                await connect()
                return true
            } else {
                loginError = "验证码错误"
                return false
            }
        } catch {
            loginError = "验证码错误或已过期"
            return false
        }
    }

    /// Abandon a pending TOTP challenge (back to the password form).
    public func cancelLogin() {
        pendingTotpToken = nil
        loginError = nil
    }

    /// Sign out: drop the token, disconnect, return to the login screen.
    public func logout() async {
        stopPolling()
        try? await api.logout()
        isConnected = false
        isConfigured = false
        token = nil
        pendingTotpToken = nil
        await api.setToken(nil)
        conversations = []
        unread = [:]
        isAuthenticated = false
    }

    /// REST refresh — also the manual retry after `.failed` (the status line in
    /// ConversationListView taps through here) and the scenePhase=.active resume.
    /// No socket: just re-sync and make sure the poll loop is running again.
    public func reconnect() async {
        guard isConfigured else { return }
        await pagedSync()
        startPolling()
    }

    /// Pull-to-refresh on the conversation list: re-sync and restart polling if
    /// it had stopped (e.g. after the failure cap).
    public func pullToRefresh() async {
        guard isConfigured else { await connect(); return }
        await pagedSync()
        startPolling()
    }

    // MARK: - REST polling (no WebSocket on watchOS)

    /// Start (or restart) the foreground poll loop. Idempotent — cancels any
    /// existing loop first. Resets the failure counter so a manual retry gets a
    /// fresh budget.
    public func startPolling() {
        pollTask?.cancel()
        syncFailureCount = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Fast cadence only while a reply is in flight; otherwise idle-slow.
                let interval = self.thinkingIds.isEmpty ? Self.idlePollNanos : Self.activePollNanos
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self.pagedSync()
            }
        }
    }

    /// Stop the poll loop (backgrounded / logout) to save battery.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Sync

    /// Recent-N per conversation on a cold start (mirrors iOS). The watch is the
    /// most memory-constrained device, so it must never stream the entire history
    /// into SwiftData — the dead `recent` cap meant it backfilled everything.
    private static let coldStartRecent = 30

    private func pagedSync() async {
        let startCursor = await storage.imSyncCursor()
        isSyncing = true
        defer { isSyncing = false }

        // Cold start: cap to recent-N per conversation; the server jumps our
        // cursor to its max rev so we skip the full message-history download.
        if startCursor == 0 {
            do {
                let resp = try await api.fetchImSync(since: 0, recent: Self.coldStartRecent)
                await engine.applySync(resp)
                await refresh()
                lastError = nil
                noteSyncSuccess()
            } catch {
                lastError = "同步失败: \(error.localizedDescription)"
                noteSyncFailure()
            }
            return
        }

        var since = startCursor
        var pages = 0
        while true {
            do {
                let resp = try await api.fetchImSync(since: since)
                await engine.applySync(resp)
                pages += 1
                let isLast = !resp.hasMore || resp.cursor <= since
                // Conversations all arrive on page 1; messages are paged. Refresh
                // after page 1 (list shows immediately) and at the end — NOT on
                // every page, which re-sorted + recomputed unread mid-backfill.
                if pages == 1 || isLast { await refresh() }
                lastError = nil
                if isLast { noteSyncSuccess(); break }
                since = resp.cursor
            } catch {
                lastError = "同步失败: \(error.localizedDescription)"
                noteSyncFailure()
                break
            }
        }
    }

    /// A sync succeeded: reset the failure budget and mark the connection online.
    private func noteSyncSuccess() {
        syncFailureCount = 0
        isConnected = true
        if connectionState != .online {
            connectionState = .online
            handleConnectionTransition(to: .online)
        }
    }

    /// A sync failed: after `maxSyncFailures` CONSECUTIVE failures, stop polling
    /// and surface `.failed` (the status line becomes a tap-to-reconnect button).
    private func noteSyncFailure() {
        syncFailureCount += 1
        isConnected = false
        if syncFailureCount >= Self.maxSyncFailures {
            stopPolling()
            if connectionState != .failed {
                connectionState = .failed
                handleConnectionTransition(to: .failed)
            }
        } else if case .reconnecting = connectionState {
            // already showing retry state
        } else if connectionState == .online {
            connectionState = .reconnecting(attempt: syncFailureCount)
            handleConnectionTransition(to: .reconnecting(attempt: syncFailureCount))
        }
    }

    public func refresh() async {
        var convs = await storage.imConversations()
        convs.sort {
            let a = ($0.isPinned ? 1 : 0, $0.lastActivityAt)
            let b = ($1.isPinned ? 1 : 0, $1.lastActivityAt)
            if a != b { return a > b }
            return $0.id < $1.id
        }
        // Drop the local delete guard once the server confirms is_deleted=1.
        if !locallyDeletedIds.isEmpty {
            locallyDeletedIds.subtract(convs.filter { $0.isDeleted }.map { $0.id })
        }
        self.conversations = convs
        self.unread = await engine.computeUnread()
        await clearAnsweredThinking()
    }

    /// REST replacement for the old socket `assistant`-message signal: a polled
    /// sync may have landed the reply, so clear the "正在输入…" line for any
    /// conversation whose newest message is now from the assistant.
    private func clearAnsweredThinking() async {
        guard !thinkingIds.isEmpty else { return }
        for id in thinkingIds {
            let latest = await storage.imMessages(conversationId: id).last
            if latest?.role == "assistant" { thinkingIds.remove(id); turnProgress[id] = nil }
        }
    }

    /// Conversations to show: hide server-synced deletes/folds/blacklist + the
    /// optimistic local-delete guard — same rules as iOS/web/macOS.
    public var visible: [ImConversationDTO] {
        conversations.filter {
            !$0.isDeleted && !locallyDeletedIds.contains($0.id)
                && !$0.isFolded
                && !isPathBlacklisted($0.contactId)
        }
    }

    public func isFolded(_ id: String) -> Bool {
        conversations.first { $0.id == id }?.isFolded ?? false
    }

    public func isPathBlacklisted(_ path: String?) -> Bool {
        guard let p = path, !p.isEmpty else { return false }
        return blacklistedPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    // MARK: - Conversation meta (server-synced via /state — same as iOS)

    private func mutateLocal(_ id: String, _ transform: (ImConversationDTO) -> ImConversationDTO) async {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        await storage.upsertImConversation(transform(conv))
        await refresh()
    }

    /// Delete (WeChat-style soft delete) — hidden on every device; a new reply
    /// resurrects it server-side. Local guard hides it instantly.
    public func setDeleted(_ id: String, _ deleted: Bool) {
        if deleted { locallyDeletedIds.insert(id) } else { locallyDeletedIds.remove(id) }
        Task {
            await mutateLocal(id) { $0.with(isDeleted: deleted) }
            try? await api.postImState(conversationId: id, isDeleted: deleted)
        }
    }

    public func setFolded(_ id: String, _ folded: Bool) {
        Task {
            await mutateLocal(id) { $0.with(isFolded: folded) }
            try? await api.postImState(conversationId: id, isFolded: folded)
        }
    }

    public func setMuted(_ id: String, _ muted: Bool) {
        Task {
            await mutateLocal(id) { $0.with(isMuted: muted) }
            try? await api.postImState(conversationId: id, isMuted: muted)
        }
    }

    public func refreshBlacklist() async {
        if let paths = try? await api.fetchBlacklist() { blacklistedPaths = Set(paths) }
    }

    public func messages(_ conversationId: String) async -> [ImMessageDTO] {
        await storage.imMessages(conversationId: conversationId)
    }

    /// Best-effort fetch of a truncated message's full body (server P2 lazy
    /// endpoint). Returns nil on any error → caller falls back to the preview.
    public func fetchMessageContent(conversationId: String, messageId: String) async -> String? {
        try? await api.fetchMessageContent(conversationId: conversationId, messageId: messageId)
    }

    public func markRead(_ conversationId: String) async {
        let seq = conversations.first { $0.id == conversationId }?.lastSeq ?? 0
        await storage.setImReadCursor(conversationId: conversationId, deviceId: deviceId, lastReadSeq: seq)
        await refresh()
        try? await api.postImRead(conversationId: conversationId, deviceId: deviceId, lastReadSeq: seq)
    }

    // MARK: - Usage / context (read-only displays)

    /// Best-effort fetch of the server's Claude usage limits (5h / 7d). Returns
    /// nil on any error so the caller can quietly render nothing.
    public func loadUsageLimits() async -> ClaudeUsageLimits? {
        try? await api.fetchClaudeUsageLimits()
    }

    /// Best-effort fetch of a conversation's context-window occupancy. Returns
    /// nil when there's no data yet or on any error.
    public func fetchConversationContext(conversationId: String) async -> ConversationContext? {
        try? await api.fetchConversationContext(conversationId: conversationId)
    }

    public func displayName(for conv: ImConversationDTO) -> String {
        if let note = conv.note, !note.isEmpty { return note }
        return conv.title ?? String(conv.id.prefix(8))
    }

    // MARK: - Send (dictated text)

    /// Send a dictated message over REST (watchOS has no WebSocket). Returns
    /// `true` once the server accepts it (202), `false` if the POST threw — the
    /// view turns a failed send into a red "!" + tap-to-resend, mirroring iOS.
    /// The reply lands later via a polled /sync; `thinkingIds` drives the
    /// "正在输入…" line until then (cleared in `clearAnsweredThinking`).
    @discardableResult
    public func send(text: String, conversationId: String, clientMsgId: String? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let conv = conversations.first { $0.id == conversationId }
        thinkingIds.insert(conversationId)
        do {
            // Reuse the optimistic pending id as the idempotency key so a resend
            // after a lost ack is a server-side no-op instead of a second run.
            try await api.sendImMessage(conversationId: conversationId, text: trimmed,
                                        projectPath: conv?.contactId, clientMsgId: clientMsgId)
            return true
        } catch {
            // Send never left the device — clear the typing line so the
            // conversation doesn't show a stuck 正在输入….
            thinkingIds.remove(conversationId)
            return false
        }
    }

    /// Answer an interactive choice card (红包-style poll) over REST (watchOS has
    /// no chat WS). `answers` for AskUserQuestion, `approve` for ExitPlanMode. The
    /// server flips the card to answered; the result re-syncs via polled /sync.
    /// Returns true on a 2xx, false if the POST threw.
    @discardableResult
    public func respondChoice(conversationId: String, requestId: String,
                              answers: [String: [String]]?, approve: Bool?) async -> Bool {
        do {
            try await api.respondChoice(conversationId: conversationId, requestId: requestId,
                                        answers: answers, approve: approve)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Connection health (transient banner)

    private func handleConnectionTransition(to state: ConnectionState) {
        switch state {
        case .online:
            if wasOnline { showBanner("已重新连接") }   // edge: restored
            wasOnline = true
        case .reconnecting:
            if wasOnline { showBanner("连接断开，正在重连…") }
        case .offline:
            if wasOnline { showBanner("网络已断开") }
        case .failed:
            showBanner("连接失败 · 请手动重连")
        }
    }

    private func showBanner(_ text: String) {
        connectionBanner = text
        let token = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if self.connectionBanner == token { self.connectionBanner = nil }
        }
    }
}
