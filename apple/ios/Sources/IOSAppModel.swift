import Foundation
import SwiftData
import ChatKit

/// iOS application state: owns the IM core (Storage / ImSyncEngine / APIClient /
/// ChatSocket), runs the initial paged sync, consumes im:* WS frames, and
/// exposes conversations + unread for the WeChat-style UI.
@MainActor
@Observable
public final class IOSAppModel {
    // MARK: - Public state
    public var conversations: [ImConversationDTO] = []
    public var unread: [String: Int] = [:]
    /// Set by the open chat screen so realtime replies for it don't notify.
    public var foregroundConversationId: String?
    /// Conversations currently awaiting an assistant reply — drives the
    /// "正在输入中..." indicator and the 中断 button.
    public var thinkingConversationIds: Set<String> = []
    /// Per-conversation live turn progress from im:status frames: (toolCount,
    /// currentTool). Cleared when the turn ends (isProcessing:false). Drives the
    /// richer "执行了 N 个操作 · 正在运行 Bash" line under "正在输入…".
    public var turnProgress: [String: (toolCount: Int, currentTool: String?)] = [:]

    /// A per-conversation progress line for the typing indicator. nil when no
    /// tools have run yet (caller shows a bare "正在输入…").
    public func progressLine(for id: String) -> String? {
        guard let p = turnProgress[id], p.toolCount > 0 else { return nil }
        return "执行了 \(p.toolCount) 个操作" + (p.currentTool.map { " · 正在运行 \($0)" } ?? "")
    }
    /// Sessions the server reports as live/active — drives the green online dot.
    public var liveSessionIds: Set<String> = []
    /// Conversations the user just deleted, kept hidden locally until the server
    /// confirms is_deleted=1 — so an in-flight /sync (which may still carry the
    /// pre-delete state) can't transiently un-hide them. PERSISTED: a delete must
    /// survive an app restart even if its /state POST was lost (app suspended
    /// mid-flight before the round-trip finished). Re-asserted to the server on
    /// launch via reassertPendingDeletes().
    public private(set) var locallyDeletedIds: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(locallyDeletedIds), forKey: Self.locallyDeletedKey) }
    }
    private static let locallyDeletedKey = "ios_locally_deleted"

    /// Transient toast surfaced when a server mutation fails; the UI shows it
    /// briefly and clears it.
    public var toast: ToastMessage?
    public struct ToastMessage: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
    }
    private func showToast(_ text: String) { toast = ToastMessage(text: text) }

    /// Run a server mutation; on failure surface a toast. The optimistic local
    /// change already applied (and pending deletes also retry on next launch).
    private func pushOrToast(_ failHint: String, _ work: () async throws -> Void) async {
        do { try await work() } catch { showToast(failHint) }
    }

    // MARK: - Tool approval (opt-in)

    /// Server waits this long for the user before auto-executing a tool on no answer.
    static let approvalTimeoutMs = 600_000   // 10 minutes

    /// When true, tool execution asks for the user's OK first (server prompts via
    /// permission_request); when false (default) every tool auto-executes
    /// (bypassPermissions). Persisted across launches.
    public var requireToolApproval: Bool {
        didSet { UserDefaults.standard.set(requireToolApproval, forKey: "ios_require_tool_approval") }
    }

    /// The tool approval currently awaiting the user's decision (one at a time).
    public var pendingApproval: ToolApprovalRequest?

    public struct ToolApprovalRequest: Identifiable, Sendable {
        public let id: String          // server requestId
        public let sessionId: String
        public let toolName: String
        public let input: String
    }

    // MARK: - Auth state
    /// true once a token is active (login succeeded or skipped with empty token)
    public var isAuthenticated: Bool = false
    /// non-nil while waiting for the user to enter a TOTP code
    public var pendingTotpToken: String?
    /// The signed-in user (nil under dev-bypass / skip-login or before fetch).
    public var currentUser: User?
    /// Last known username, persisted so an OFFLINE launch (where /api/auth/user
    /// fails) still shows who you are instead of flipping to "本地测试".
    private var cachedUsername: String? {
        didSet { UserDefaults.standard.set(cachedUsername, forKey: "ios_username") }
    }
    /// Whether the realtime WS is currently connected — drives the "我" tab status.
    public var isConnected: Bool = false
    /// 3-state connection health (online / reconnecting / offline) surfaced in the
    /// 我 tab and via a transient banner. `isConnected` is derived from this.
    public var connectionState: ConnectionState = .reconnecting(attempt: 0)
    /// Last ping→pong round-trip latency in ms; nil until first sample / offline.
    public var latencyMs: Int? = nil
    /// Transient edge banner shown on drop/restore; auto-hides after ~3s.
    public var connectionBanner: String? = nil
    private var wasOnline = false
    /// True while the first /sync backfill is still running (so the chat list can
    /// show "正在同步…" instead of a bare empty state).
    public var isSyncing: Bool = false
    /// Last sync/connection error, surfaced in the UI so a failed sync no longer
    /// looks like an empty inbox.
    public var lastSyncError: String?
    /// The active server base URL as a string, for display in settings.
    public var serverURLString: String { _activeBaseURL.absoluteString }
    /// Single source of truth for *my* avatar — used by both the 我 tab and the
    /// outgoing chat bubbles so they always match.
    public var myAvatarSeed: String {
        (currentUser?.username ?? cachedUsername).map { "user-\($0)" } ?? "me"
    }
    public var myDisplayName: String { currentUser?.username ?? cachedUsername ?? "本地测试" }

    // MARK: - Private core
    private let storage: Storage
    private let engine: ImSyncEngine
    private let api: APIClient
    private let socket: ChatSocket
    private let deviceId: String
    /// In-memory cache of image bytes by mediaId (immutable, so never stale).
    private let mediaDataCache = NSCache<NSString, NSData>()
    /// Cached base URL so we don't need to cross the actor boundary to read it.
    private var _activeBaseURL: URL = URL(string: "http://127.0.0.1:3001")!
    private var _pendingBaseURL: URL?

    /// Server-synced blacklisted project paths (mirror of /api/im/blacklist).
    public var blacklistedPaths: Set<String> = []

    /// Optimistic choice answers (requestId → result summary): shown the instant
    /// the user submits, before the server's authoritative answered card
    /// re-syncs, so the card flips immediately instead of after a /sync lag.
    public var optimisticChoiceAnswers: [String: String] = [:]
    /// Choice cards whose submit FAILED — render a red ! so the user can retry.
    public var failedChoiceAnswers: Set<String> = []

    // MARK: - Init

    public init() {
        let fixedProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let container = (try? StorageContainer.makeOnDisk(profileId: fixedProfile))
            ?? (try! StorageContainer.makeInMemory())
        self.storage = Storage(container: container)
        self.engine = ImSyncEngine(storage: storage)
        self.api = APIClient()
        self.socket = ChatSocket()
        self.deviceId = DeviceIdentity.current()
        self.requireToolApproval = UserDefaults.standard.bool(forKey: "ios_require_tool_approval")
        self.cachedUsername = UserDefaults.standard.string(forKey: "ios_username")
        if let saved = UserDefaults.standard.array(forKey: Self.locallyDeletedKey) as? [String] {
            self.locallyDeletedIds = Set(saved)
        }
    }

    /// Respond to the pending tool-approval prompt and forward the decision to
    /// the server (which resolves the waiting canUseTool call).
    public func respondToApproval(_ requestId: String, allow: Bool) async {
        if pendingApproval?.id == requestId { pendingApproval = nil }
        try? await socket.send(.toolApprovalResponse(requestId: requestId, allow: allow))
    }

    /// Answer an interactive choice card (红包-style poll) with OPTIMISTIC UI:
    /// flip the card to answered locally the instant the user submits, send the
    /// answer over REST `/respond` (which gives a real accept/reject signal, vs a
    /// WS send that returns before the server processes it), then pull an
    /// immediate /sync for the authoritative answered card. On failure, revert
    /// and flag the card with a red ! so the user can retry.
    /// `answers` for AskUserQuestion, `approve` for ExitPlanMode; `summary` is the
    /// optimistic "已选择 …" label.
    @discardableResult
    public func answerChoice(conversationId: String, requestId: String,
                             answers: [String: [String]]?, approve: Bool?,
                             summary: String) async -> Bool {
        failedChoiceAnswers.remove(requestId)
        optimisticChoiceAnswers[requestId] = summary   // instant flip
        do {
            try await api.respondChoice(conversationId: conversationId, requestId: requestId,
                                        answers: answers, approve: approve)
            await pagedSync()   // pull the authoritative answered card now
            await refresh()
            return true
        } catch {
            optimisticChoiceAnswers[requestId] = nil    // revert the optimistic flip
            failedChoiceAnswers.insert(requestId)
            print("[IOSAppModel] answerChoice failed: \(error)")
            return false
        }
    }

    // MARK: - Conversation meta (server-synced via /state; broadcasts a poke)

    /// Fold/unfold — optimistic local update, then persist to the server.
    public func setFolded(_ id: String, _ folded: Bool) {
        Task {
            await mutateLocal(id) { c in c.with(isFolded: folded) }
            await pushOrToast("折叠未同步,请检查网络") {
                try await self.api.postImState(conversationId: id, isFolded: folded)
            }
        }
    }
    public func isFolded(_ id: String) -> Bool {
        conversations.first { $0.id == id }?.isFolded ?? false
    }

    /// Delete a conversation (WeChat-style): hidden on every client. The local
    /// guard is PERSISTED and re-asserted on launch, so the delete survives even
    /// if its /state POST is lost (app suspended mid-flight). A later inbound
    /// message resurrects it (the server clears the flag), so a live chat is
    /// never lost.
    public func setDeleted(_ id: String, _ deleted: Bool) {
        // Update the local guard SYNCHRONOUSLY (before the async Task) so the row
        // disappears the instant the user taps — no re-sort can shift the open
        // swipe onto a neighbouring row, and a concurrent /sync can't un-hide it
        // before the server commits.
        if deleted { locallyDeletedIds.insert(id) } else { locallyDeletedIds.remove(id) }
        Task {
            await mutateLocal(id) { c in c.with(isDeleted: deleted) }
            await pushOrToast(deleted ? "删除未同步到服务器,启动时会自动重试" : "操作未同步,请检查网络") {
                try await self.api.postImState(conversationId: id, isDeleted: deleted)
            }
        }
    }

    /// Resolved nickname: note → title → id.
    public func displayName(for conv: ImConversationDTO) -> String {
        if let note = conv.note, !note.isEmpty { return note }
        return conv.title ?? String(conv.id.prefix(8))
    }

    /// Set/clear a conversation's custom nickname — optimistic + server.
    public func setNote(_ conversationId: String, _ note: String?) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = (trimmed?.isEmpty == false) ? trimmed : nil
        Task {
            await mutateLocal(conversationId) { c in c.with(note: value) }
            await pushOrToast("备注未同步,请检查网络") {
                try await self.api.postImState(conversationId: conversationId, note: .some(value))
            }
        }
    }

    // MARK: - Blacklist (server-synced)

    public func refreshBlacklist() async {
        if let paths = try? await api.fetchBlacklist() { blacklistedPaths = Set(paths) }
    }

    /// Re-push any locally-pending deletes the server hasn't recorded yet. A
    /// delete POST can be lost if the app is suspended mid-flight; the guard is
    /// persisted, so on launch we make the intent durable (and cross-device).
    private func reassertPendingDeletes() async {
        guard !locallyDeletedIds.isEmpty else { return }
        let unconfirmed = locallyDeletedIds.filter { id in
            !(conversations.first { $0.id == id }?.isDeleted ?? false)
        }
        for id in unconfirmed {
            try? await api.postImState(conversationId: id, isDeleted: true)
        }
    }
    public func setBlacklisted(_ path: String, _ blacklisted: Bool) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if blacklisted { blacklistedPaths.insert(p) } else { blacklistedPaths.remove(p) }
        Task {
            await pushOrToast(blacklisted ? "屏蔽未同步,请检查网络" : "取消屏蔽未同步,请检查网络") {
                if blacklisted { try await self.api.addBlacklist(path: p) }
                else { try await self.api.removeBlacklist(path: p) }
            }
            await refresh()
        }
    }

    /// A path is blacklisted if it equals, or is nested under, a listed path.
    public func isPathBlacklisted(_ path: String?) -> Bool {
        guard let p = path else { return false }
        return blacklistedPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
    public func isBlacklisted(_ conv: ImConversationDTO) -> Bool {
        isPathBlacklisted(conv.contactId)
    }

    // MARK: - Boot

    /// Initial paged sync, connect the WS, and consume im:* frames.
    public func start(baseURL: URL, token: String) async {
        _activeBaseURL = baseURL
        await api.setBaseURL(baseURL)
        await api.setToken(token.isEmpty ? nil : token)
        // Show cached history IMMEDIATELY from local storage so opening the app
        // isn't a full-screen "正在同步" — the network sync then refreshes in place
        // (a small top spinner covers it).
        await refresh()
        // Best-effort identity. Only OVERWRITE on success — a failed fetch while
        // offline must NOT wipe a known user to nil (that flipped the 我 tab to
        // "本地测试"). The username is also cached to survive an offline launch.
        if let u = try? await api.currentUser() {
            currentUser = u
            cachedUsername = u.username
        }
        await pagedSync()
        await refresh()
        await reassertPendingDeletes()
        await refreshLiveSessions()
        await refreshBlacklist()
        do {
            try await socket.connect(baseURL: baseURL, token: token)
            isConnected = true
            // Mirror ping→pong latency samples onto this @Observable model.
            await socket.setLatencyHandler { [weak self] ms in
                Task { @MainActor in self?.latencyMs = ms }
            }
            let stream = await socket.events
            Task { await consume(stream) }
        } catch {
            isConnected = false
            print("[IOSAppModel] socket connect failed: \(error)")
        }
    }

    // MARK: - Auth

    /// Login with username/password; handles the TOTP continuation by setting
    /// `pendingTotpToken` when the server requires a second factor.
    /// Returns `true` if fully authenticated (token obtained), `false` if either
    /// login failed or is waiting for TOTP (check `pendingTotpToken` for the latter).
    @discardableResult
    public func login(baseURL: URL, username: String, password: String) async -> Bool {
        _pendingBaseURL = baseURL
        await api.setBaseURL(baseURL)
        do {
            let resp = try await api.login(username: username, password: password)
            if let token = resp.token {
                persistCredentials(baseURL: baseURL, token: token)
                await api.setToken(token)
                isAuthenticated = true
                Task { await start(baseURL: baseURL, token: token) }
                return true
            } else if resp.requiresTotp == true, let totpToken = resp.totpToken {
                // Surface TOTP sheet; stash context for submitTOTP
                self.pendingTotpToken = totpToken
                return false
            } else {
                return false
            }
        } catch {
            print("[IOSAppModel] login error: \(error)")
            return false
        }
    }

    /// Submit a TOTP code after a `login` returned `requiresTotp`.
    @discardableResult
    public func submitTOTP(code: String) async -> Bool {
        guard let totpToken = pendingTotpToken else { return false }
        let baseURL = _pendingBaseURL ?? _activeBaseURL
        do {
            let resp = try await api.loginWithTOTP(totpToken: totpToken, code: code)
            if let token = resp.token {
                persistCredentials(baseURL: baseURL, token: token)
                await api.setToken(token)
                pendingTotpToken = nil
                _pendingBaseURL = nil
                isAuthenticated = true
                Task { await start(baseURL: baseURL, token: token) }
                return true
            } else {
                return false
            }
        } catch {
            print("[IOSAppModel] TOTP error: \(error)")
            return false
        }
    }

    /// Cancel a pending TOTP challenge (user tapped "取消").
    public func cancelTOTP() {
        pendingTotpToken = nil
        _pendingBaseURL = nil
    }

    /// Skip login and connect with an empty token (testing phase / auth disabled).
    @discardableResult
    public func loginSkip(baseURL: URL) async -> Bool {
        persistCredentials(baseURL: baseURL, token: "")
        isAuthenticated = true
        Task { await start(baseURL: baseURL, token: "") }
        return true
    }

    /// Restore credentials from UserDefaults; returns true if credentials exist.
    public func restoreSession() -> Bool {
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: "ios_baseURL"),
              let url = URL(string: urlString) else { return false }
        let token = defaults.string(forKey: "ios_token") ?? ""
        isAuthenticated = true
        Task {
            await start(baseURL: url, token: token)
        }
        return true
    }

    /// Launch bootstrap: restore a non-empty stored token; otherwise auto-skip
    /// ONLY if the server runs in DEV_AUTH_BYPASS; otherwise stay logged out so
    /// the login screen appears. Replaces the old unconditional restoreSession()
    /// so a stale/empty token no longer "logs in" against an auth-enforcing server.
    public func bootstrap() async {
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: "ios_baseURL").flatMap { URL(string: $0) }
        if let url = storedURL,
           let token = defaults.string(forKey: "ios_token"), !token.isEmpty {
            isAuthenticated = true
            await start(baseURL: url, token: token)
            return
        }
        // No usable token — let a DEV_AUTH_BYPASS server through without login.
        let url = storedURL ?? _activeBaseURL
        await api.setBaseURL(url)
        if await api.devAuthBypassed() {
            await loginSkip(baseURL: url)
        }
        // else: stay .loggedOut → LoginView
    }

    /// Sign out: tear down the socket, forget credentials, and return to login.
    public func signOut() async {
        await socket.disconnect()
        isConnected = false
        UserDefaults.standard.removeObject(forKey: "ios_token")
        // Keep the base URL so the login screen pre-fills the last server.
        currentUser = nil
        conversations = []
        unread = [:]
        foregroundConversationId = nil
        isAuthenticated = false
        IOSNotifications.setBadge(0)
    }

    // MARK: - Discover (skills + slash commands)

    /// Fetch the directory of slash commands + skills the server exposes.
    public func availableCommands() async -> [CommandInfo] {
        do {
            return try await api.fetchCommands(projectPath: nil)
        } catch {
            print("[IOSAppModel] fetchCommands failed: \(error)")
            return []
        }
    }

    // MARK: - Usage / context (read-only displays)

    /// Best-effort fetch of the server's Claude usage limits (5h / 7d). Returns
    /// nil on any error so the caller can quietly show "暂无数据".
    /// Bytes of an assistant-sent image (kind:'image'), cached in memory
    /// (NSCache) and on disk (Caches/im-media/<mediaId>). The mediaId is immutable
    /// (content-addressed), so a cache hit is always valid — no re-download on
    /// scroll, on re-entering the chat, or across app launches.
    public func loadMedia(mediaId: String, thumb: Bool = false) async -> Data? {
        let key = ((thumb ? "thumb:" : "orig:") + mediaId) as NSString
        if let cached = mediaDataCache.object(forKey: key) { return cached as Data }

        let fileName = thumb ? "\(mediaId).thumb" : mediaId
        let diskURL = Self.mediaCacheDir().appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: diskURL), !data.isEmpty {
            mediaDataCache.setObject(data as NSData, forKey: key)
            return data
        }

        do {
            let data = try await api.fetchMedia(id: mediaId, thumb: thumb)
            mediaDataCache.setObject(data as NSData, forKey: key)
            try? data.write(to: diskURL)   // persist across launches (immutable id)
            return data
        } catch {
            print("[IOSAppModel] fetchMedia failed: \(error)")
            return nil
        }
    }

    /// On-disk image cache directory (auto-purged by the OS under disk pressure).
    nonisolated static func mediaCacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("im-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func loadUsageLimits(force: Bool = false) async -> ClaudeUsageLimits? {
        do {
            return try await api.fetchClaudeUsageLimits(force: force)
        } catch {
            print("[IOSAppModel] fetchClaudeUsageLimits failed: \(error)")
            return nil
        }
    }

    /// Best-effort fetch of a conversation's context-window occupancy. Returns
    /// nil when there's no data yet or on any error.
    public func fetchConversationContext(conversationId: String) async -> ConversationContext? {
        do {
            return try await api.fetchConversationContext(conversationId: conversationId)
        } catch {
            print("[IOSAppModel] fetchConversationContext failed: \(error)")
            return nil
        }
    }

    // MARK: - Conversation state (pin)

    /// Toggle pin for a conversation: update the local cache immediately for a
    /// snappy list re-sort, then persist to the server.
    public func setPinned(_ conversationId: String, _ pinned: Bool) async {
        await mutateLocal(conversationId) { c in c.with(isPinned: pinned) }
        await pushOrToast("置顶未同步,请检查网络") {
            try await self.api.postImState(conversationId: conversationId, isPinned: pinned)
        }
    }

    /// Toggle mute (免打扰) — muted chats don't post notifications.
    public func setMuted(_ conversationId: String, _ muted: Bool) async {
        await mutateLocal(conversationId) { c in c.with(isMuted: muted) }
        await pushOrToast("免打扰未同步,请检查网络") {
            try await self.api.postImState(conversationId: conversationId, isMuted: muted)
        }
    }

    private func mutateLocal(_ conversationId: String, _ transform: (ImConversationDTO) -> ImConversationDTO) async {
        if let conv = conversations.first(where: { $0.id == conversationId }) {
            await storage.upsertImConversation(transform(conv))
        }
        await refresh()
    }

    /// Pull the server's live/active session ids for the online indicator.
    public func refreshLiveSessions() async {
        do {
            let live = try await api.fetchSessions()
            liveSessionIds = Set(live.filter { $0.isActive == true }.map(\.id))
        } catch {
            // Best-effort; leave the prior set in place on failure.
        }
    }

    // MARK: - Private helpers

    private func persistCredentials(baseURL: URL, token: String) {
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "ios_baseURL")
        UserDefaults.standard.set(token, forKey: "ios_token")
    }

    /// How many recent messages per conversation to pull on a cold start. A few
    /// conversations hold 1000+ messages; capping keeps the first sync (and the
    /// CPU/heat it caused) small. Older history loads via the transcript view.
    private static let coldStartRecent = 30

    private func pagedSync() async {
        // Re-entrancy guard: entering several chats quickly (or a poke burst) used
        // to launch overlapping paged syncs, all hammering the serial Storage
        // actor and starving the chat the user is looking at. Collapse to one.
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let startCursor = await storage.imSyncCursor()

        // Cold start (empty local store): pull only recent-N per conversation and
        // let the server jump our cursor to its max rev, instead of streaming the
        // entire message history (~5000 rows → ~600).
        if startCursor == 0 {
            do {
                let resp = try await api.fetchImSync(since: 0, recent: Self.coldStartRecent)
                await engine.applySync(resp)
                await refresh()
                lastSyncError = nil
            } catch {
                lastSyncError = "同步失败: \(error.localizedDescription)"
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
                // The full conversation set arrives on the FIRST page; messages
                // are paged. Refresh after page 1 (list shows immediately) and at
                // the end — NOT on every one of the ~25 pages, which re-rendered
                // the whole 157-row list mid-scroll and caused the jank.
                if pages == 1 || isLast { await refresh() }
                lastSyncError = nil
                if isLast { break }
                since = resp.cursor
            } catch {
                // Surface the failure — a silently-swallowed error here is exactly
                // why "logged in but no conversations" looked like an empty inbox.
                lastSyncError = "同步失败: \(error.localizedDescription)"
                print("[IOSAppModel] sync failed at page \(pages): \(error)")
                break
            }
        }
    }

    // Debounced refresh/sync so a machine that auto-runs many sessions (lots of
    // im:message / im:poke broadcasts) doesn't hammer the main actor and stall
    // the chat the user is actually looking at.
    private var refreshScheduled = false
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            // Coalesce to ~1s — the user confirmed a 1s delay is fine, and it
            // keeps an auto-running machine's firehose of frames from re-rendering
            // the list (and recomputing unread) more than once a second.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshScheduled = false
            await refresh()
        }
    }
    private var syncScheduled = false
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            syncScheduled = false
            await pagedSync()
            await refreshBlacklist()
            await refresh()
        }
    }

    /// Per-conversation debounced reply notification. The distilled assistant
    /// reply streams as many im:message edits per turn; rescheduling on each one
    /// collapses them into a SINGLE notification ~3s after the reply settles
    /// (with the latest preview), instead of one-per-tool-execution.
    private var notifDebounce: [String: Task<Void, Never>] = [:]
    /// Reply ids already notified — the distilled result re-broadcasts on every
    /// content edit / tool_use, so a tool slower than the debounce window would
    /// otherwise fire a SECOND (duplicate, same-content) notification. One per
    /// reply turn, full stop.
    private var notifiedReplyIds: Set<String> = []
    private func scheduleAssistantNotification(_ conversationId: String, replyId: String,
                                               title: String, preview: String) {
        if notifiedReplyIds.contains(replyId) { return }
        notifDebounce[conversationId]?.cancel()
        notifDebounce[conversationId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            notifDebounce[conversationId] = nil
            // Re-check at fire time: the user may have opened the chat meanwhile,
            // or another frame for this same reply already notified.
            guard conversationId != foregroundConversationId else { return }
            guard !notifiedReplyIds.contains(replyId) else { return }
            notifiedReplyIds.insert(replyId)
            if notifiedReplyIds.count > 1000 { notifiedReplyIds.removeAll() } // cap
            IOSNotifications.notifyAssistantReply(
                conversationTitle: title, preview: preview, totalUnread: totalUnread)
        }
    }

    private func consume(_ stream: AsyncStream<ServerEvent>) async {
        for await event in stream {
            switch event {
            case .imPoke:
                scheduleSync()
            case .sessionCreated:
                // A fresh session was bootstrapped — pull it in. Coalesced: a
                // burst of session events collapses into one sync.
                scheduleSync()
                continue
            case let .imMessage(conversationId, message):
                await engine.applyFrame(event)
                // An assistant reply ends the "typing" state for that chat.
                if message.role == "assistant" {
                    thinkingConversationIds.remove(conversationId)
                    turnProgress[conversationId] = nil
                }
                // ALWAYS coalesce list refreshes — an auto-running machine
                // streams a firehose of im:message frames (one per content edit),
                // and calling refresh() (which recomputes unread over every reply
                // row) on each one pegged the CPU and cooked the phone. The open
                // chat picks up new messages via ChatDetailView's own lastSeq
                // reload within the debounce window.
                scheduleRefresh()
                let isForeground = (conversationId == foregroundConversationId)
                let conv = conversations.first { $0.id == conversationId }
                let suppressed = (conv?.isMuted ?? false) || isPathBlacklisted(conv?.contactId)
                // The distilled assistant reply (kind result/error) is re-broadcast
                // on EVERY streaming content-edit, so notifying per frame fired a
                // notification for every tool the turn ran. Debounce per
                // conversation: only one notification fires ~after the reply
                // settles, with the latest preview.
                let isReplyTurn = (message.kind == "result" || message.kind == "error")
                if message.role == "assistant", isReplyTurn, !isForeground, !suppressed {
                    scheduleAssistantNotification(
                        conversationId,
                        replyId: message.id,
                        title: conv?.title ?? "对话",
                        preview: String(message.content.prefix(80)))
                }
                continue
            case .imRead:
                await engine.applyFrame(event)
                scheduleRefresh()
                continue
            // Chat-path frames on our own socket tell us when Claude is working.
            case let .sessionStatus(sessionId, isProcessing):
                if isProcessing {
                    thinkingConversationIds.insert(sessionId)
                } else {
                    thinkingConversationIds.remove(sessionId)
                    turnProgress[sessionId] = nil
                    // Coalesce: many sessions finishing at once → one sync.
                    scheduleSync()
                }
                continue
            // Richer turn progress (toolCount / currentTool), throttled by server.
            case let .imStatus(conversationId, isProcessing, toolCount, currentTool):
                if isProcessing {
                    thinkingConversationIds.insert(conversationId)
                    turnProgress[conversationId] = (toolCount, currentTool)
                } else {
                    thinkingConversationIds.remove(conversationId)
                    turnProgress[conversationId] = nil
                    scheduleSync()
                }
                continue
            case let .complete(sessionId, _, _, _):
                thinkingConversationIds.remove(sessionId)
                turnProgress[sessionId] = nil
                // The reply normally arrives as a live im:message, but the
                // file-watcher distill can lag or a frame can be missed — pull
                // from the server so the new messages are never lost. Coalesced.
                scheduleSync()
                continue
            case let .error(sessionId, _):
                if let s = sessionId { thinkingConversationIds.remove(s); turnProgress[s] = nil }
                continue
            case let .permissionRequest(sessionId, requestId, toolName, input, _):
                // Only surface a prompt when the user opted in (otherwise the
                // server is in bypass mode and shouldn't send these).
                if requireToolApproval {
                    pendingApproval = ToolApprovalRequest(
                        id: requestId, sessionId: sessionId, toolName: toolName, input: input)
                }
                continue
            case let .permissionCancelled(_, requestId, _):
                // Server timed out (auto-executed) or cancelled — drop the prompt.
                if pendingApproval?.id == requestId { pendingApproval = nil }
                continue
            case let .connection(state):
                self.connectionState = state
                self.isConnected = (state == .online)
                // A non-online link has no meaningful latency — clear it.
                if state != .online { self.latencyMs = nil }
                self.handleConnectionTransition(to: state)
                continue
            default:
                break
            }
            scheduleRefresh()
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

    // MARK: - Public API

    public var totalUnread: Int {
        // Blacklisted conversations never contribute to the badge.
        guard !blacklistedPaths.isEmpty else { return unread.values.reduce(0, +) }
        let blocked = Set(conversations.filter { isBlacklisted($0) }.map(\.id))
        return unread.reduce(0) { $0 + (blocked.contains($1.key) ? 0 : $1.value) }
    }

    public func refresh() async {
        var convs = await storage.imConversations()
        convs.sort {
            let a = ($0.isPinned ? 1 : 0, $0.lastActivityAt)
            let b = ($1.isPinned ? 1 : 0, $1.lastActivityAt)
            // Stable tiebreak on id so equal-activity rows keep a fixed order and
            // the list doesn't jiggle (which mis-targets an open swipe).
            if a != b { return a > b }
            return $0.id < $1.id
        }
        // Once the server confirms a delete (is_deleted=1 arrives via /sync), drop
        // the local guard — isDeleted now carries the hidden state, and a later
        // resurrection (server clears it on a new message) can surface it again.
        if !locallyDeletedIds.isEmpty {
            locallyDeletedIds.subtract(convs.filter { $0.isDeleted }.map { $0.id })
        }
        let u = await engine.computeUnread()
        self.conversations = convs
        self.unread = u
        IOSNotifications.setBadge(totalUnread)
        // Warm avatar images in the background so the first scroll doesn't fire
        // ~150 inline network fetches (no-op once cached).
        IOSAvatarImageCache.shared.prefetch(seeds: convs.map(\.id) + [myAvatarSeed])
        await clearAnsweredThinking()
    }

    /// Self-healing fallback for a stuck "正在输入… · 执行了 N 个操作" row. It
    /// normally clears on the one-shot im:status(false) frame, but that frame is
    /// lost if we're mid-reconnect when a long turn ends — the reply then lands
    /// via /sync (not a live frame) and the row sticks forever. So after every
    /// refresh, drop progress for any conversation whose newest stored message is
    /// already an assistant reply (no turn can be in flight). An active turn
    /// re-lights via the next im:status(true). Mirrors watchOS clearAnsweredThinking.
    private func clearAnsweredThinking() async {
        guard !thinkingConversationIds.isEmpty || !turnProgress.isEmpty else { return }
        let ids = Set(thinkingConversationIds).union(turnProgress.keys)
        for id in ids {
            // fetchLimit=1 — don't load the whole conversation just to read its
            // last row (that full fetch on every refresh was a stall source).
            let latest = await storage.lastImMessage(conversationId: id)
            if latest?.role == "assistant" {
                thinkingConversationIds.remove(id)
                turnProgress[id] = nil
            }
        }
    }

    /// Pull anything missed since the last sync (e.g. a reply that completed
    /// while the realtime socket was idle/half-open). Cheap when up to date —
    /// the incremental /sync from the stored cursor returns no new messages.
    public func syncNow() async {
        await pagedSync()
    }

    /// Pull-to-refresh on the conversation list: re-fetch conversations +
    /// messages, the live-session set and the blacklist. The server returns the
    /// full conversation list on every /sync, so this refreshes previews, pins,
    /// notes, etc. — not just new messages.
    public func pullRefresh() async {
        await syncNow()
        await refreshLiveSessions()
        await refreshBlacklist()
    }

    public func messages(_ conversationId: String) async -> [ImMessageDTO] {
        await storage.imMessages(conversationId: conversationId)
    }

    /// Windowed read: the most-recent `limit` messages. The chat view loads the
    /// tail and pages older on demand, instead of pulling a whole long
    /// conversation into memory on every reload (the main-actor jank source).
    public func messages(_ conversationId: String, limit: Int) async -> [ImMessageDTO] {
        await storage.imMessages(conversationId: conversationId, limit: limit)
    }

    /// Total messages held locally for a conversation (to decide window-grow vs
    /// server back-fill in "加载更早的消息").
    public func localMessageCount(_ conversationId: String) async -> Int {
        await storage.imMessageCount(conversationId: conversationId)
    }

    /// How many older messages to back-fill per "加载更早的消息" tap.
    static let loadOlderPageSize = 30

    /// Back-fill older history for a conversation: fetch the page of messages
    /// just BEFORE `beforeSeq` from the server and write them into local
    /// storage. The chat view then re-reads via `messages(_:)` and they appear
    /// prepended. Returns whether the server *might* have more older messages
    /// (true when it returned a full page) so the view can hide the affordance
    /// once fully back-filled. Returns false on error (treated as "stop").
    @discardableResult
    public func loadOlder(conversationId: String, beforeSeq: Int) async -> Bool {
        do {
            let older = try await api.fetchImMessages(
                conversationId: conversationId,
                anchor: beforeSeq,
                numBefore: Self.loadOlderPageSize,
                numAfter: 0)
            await storage.upsertImMessages(older)
            // A short page means the server has nothing older left.
            return older.count >= Self.loadOlderPageSize
        } catch {
            return false
        }
    }

    public func markRead(_ conversationId: String) async {
        let seq = conversations.first { $0.id == conversationId }?.lastSeq ?? 0
        await storage.setImReadCursor(conversationId: conversationId, deviceId: deviceId, lastReadSeq: seq)
        await refresh()
        IOSNotifications.setBadge(totalUnread)
        try? await api.postImRead(conversationId: conversationId, deviceId: deviceId, lastReadSeq: seq)
    }

    // MARK: - Send message (feature 2)

    /// Send a user text message in a conversation via claude-command WS frame.
    @discardableResult
    public func send(text: String, conversationId: String, clientMsgId: String) async -> Bool {
        let conv = conversations.first { $0.id == conversationId }
        let projectPath = conv?.contactId
        // Default: bypass = auto-execute every tool (no prompts). When the user
        // turns on "工具执行前确认", switch to default mode so the server asks,
        // with a 10-min window that auto-executes on timeout (so an unanswered
        // prompt never stalls the run).
        let event = ClientEvent.claudeCommand(
            prompt: text,
            sessionId: conversationId,
            projectPath: projectPath,
            modelId: nil,
            resume: true,
            permissionMode: requireToolApproval ? nil : .bypassPermissions,
            approvalTimeoutMs: requireToolApproval ? Self.approvalTimeoutMs : nil,
            autoApproveOnTimeout: requireToolApproval ? true : nil,
            // Reuse the optimistic pending id as the idempotency key so a resend
            // (manual red-! tap or auto-flush on reconnect) is a server no-op.
            clientMsgId: clientMsgId
        )
        var ok = false
        do {
            try await socket.send(event)
            thinkingConversationIds.insert(conversationId)
            ok = true
        } catch {
            // Socket reported dead on send — reconnect and retry once so the
            // message isn't silently lost.
            print("[IOSAppModel] send failed, reconnecting: \(error)")
            try? await socket.reconnect()
            do {
                try await socket.send(event)
                thinkingConversationIds.insert(conversationId)
                ok = true
            } catch {
                print("[IOSAppModel] send retry failed: \(error)")
            }
        }
        isConnected = await socket.isConnected
        return ok
    }

    /// Fire an immediate ping to refresh `latencyMs` on demand (e.g. from the
    /// 我 tab). No-op if the socket isn't connected.
    public func pingNow() async {
        await socket.ping()
    }

    /// Force a WS reconnect (e.g. on foreground) + resync. iOS suspends sockets
    /// in the background; the returned task is often half-open until we rebuild.
    public func reconnect() async {
        guard isAuthenticated else { return }
        do {
            // The existing consume loop stays attached to the same AsyncStream
            // (ChatSocket never finishes it), so no new consumer is needed.
            try await socket.reconnect()
            isConnected = await socket.isConnected
        } catch {
            isConnected = false
            print("[IOSAppModel] reconnect failed: \(error)")
        }
        await pagedSync()
        await refresh()
        await refreshLiveSessions()
        // Reconcile stuck "正在输入中…": if a reply's `complete` frame was missed
        // while the app was suspended, the thinking flag never cleared. The
        // server's live-session set is authoritative — drop any thinking id it no
        // longer reports as processing.
        thinkingConversationIds.formIntersection(liveSessionIds)
    }

    // MARK: - New session / contacts

    /// All projects (contacts) with a usable working directory.
    public func projects() async -> [ProjectInfo] {
        do { return try await api.fetchProjects() }
        catch { print("[IOSAppModel] fetchProjects failed: \(error)"); return [] }
    }

    /// Create a new contact (project). Returns the created project or nil.
    public func createContact(path: String, customName: String?) async -> ProjectInfo? {
        do {
            let p = try await api.createProject(path: path, customName: customName)
            await refresh()
            return p
        } catch {
            print("[IOSAppModel] createProject failed: \(error)")
            return nil
        }
    }

    /// Bootstrap a new chat in `projectPath` by sending the first prompt with a
    /// nil sessionId (the server allocates the id + creates the IM conversation,
    /// then pokes us). Polls up to 30s for the new conversation and returns its id.
    public func startNewSession(projectPath: String, firstPrompt: String) async -> String? {
        let existing = Set(conversations.map(\.id))
        let event = ClientEvent.claudeCommand(
            prompt: firstPrompt, sessionId: nil, projectPath: projectPath,
            modelId: nil, resume: false, permissionMode: .bypassPermissions)
        do {
            try await socket.send(event)
        } catch {
            print("[IOSAppModel] startNewSession send failed: \(error)")
            return nil
        }
        // The consume loop applies the poke/sessionCreated → refresh; poll for a
        // brand-new conversation in this project.
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let fresh = conversations.first(where: {
                !existing.contains($0.id) && ($0.contactId == projectPath)
            }) {
                thinkingConversationIds.insert(fresh.id)
                return fresh.id
            }
        }
        return nil
    }

    /// Interrupt the in-flight reply for a conversation.
    public func abort(_ conversationId: String) async {
        thinkingConversationIds.remove(conversationId)
        do {
            try await socket.send(.abortSession(sessionId: conversationId))
        } catch {
            print("[IOSAppModel] abort failed: \(error)")
        }
    }

    // MARK: - Long-message full text (server P2 lazy endpoint)

    /// Best-effort fetch of a truncated message's full body. Returns nil on any
    /// error so the caller can fall back to the (truncated) preview.
    public func fetchMessageContent(conversationId: String, messageId: String) async -> String? {
        do { return try await api.fetchMessageContent(conversationId: conversationId, messageId: messageId) }
        catch { print("[IOSAppModel] fetchMessageContent failed: \(error)"); return nil }
    }

    // MARK: - Transcript (feature 3)

    /// Fetch the first page of the raw transcript for a conversation.
    /// Caller can pass `anchor` (entry id) to page backwards.
    public func fetchTranscript(conversationId: String, anchor: String? = nil) async -> ImTranscriptPage {
        do {
            // No anchor → latest page; with anchor → older entries. Both walk
            // backwards (numBefore), matching the server's newest-first contract.
            return try await api.fetchImTranscript(
                conversationId: conversationId,
                anchor: anchor,
                numBefore: 40,
                numAfter: 0
            )
        } catch {
            print("[IOSAppModel] fetchTranscript failed: \(error)")
            // Synthesize an empty page without calling a non-public memberwise init
            let emptyJSON = #"{"entries":[],"hasMoreBefore":false,"hasMoreAfter":false}"#
            return (try? JSONDecoder().decode(ImTranscriptPage.self, from: Data(emptyJSON.utf8)))!
        }
    }
}
