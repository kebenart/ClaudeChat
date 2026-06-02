import Foundation

// ============================================================================
// Network layer contracts (Agent A implements)
// ============================================================================

public protocol APIClientProtocol: Sendable {
    /// Set the active server base URL. Subsequent requests use this base.
    func setBaseURL(_ url: URL) async
    /// Set the bearer token attached to every request. Pass nil to clear.
    func setToken(_ token: String?) async

    // Auth
    func authStatus() async throws -> Bool                                // /api/auth/status
    /// Returns true when the server was started with `DEV_AUTH_BYPASS=1` and
    /// the login UI should be skipped entirely. Network failures yield `false`.
    func devAuthBypassed() async -> Bool
    func login(username: String, password: String) async throws -> LoginResponse  // /api/auth/login
    /// Second factor. `totpToken` is the short-lived JWT returned in the first /login response.
    func loginWithTOTP(totpToken: String, code: String) async throws -> LoginResponse  // /api/auth/login/totp
    func currentUser() async throws -> User                                // /api/auth/user
    func logout() async throws                                             // /api/auth/logout

    /// Request a new TOTP secret + provisioning URI for first-time setup.
    /// Requires a valid bearer token. Returns the plain secret, the otpauth:// URI,
    /// and a one-shot recovery code. Backend: POST /api/auth/totp/setup.
    func setupTOTP() async throws -> (secret: String, provisioningUri: String, recoveryCode: String)

    /// Confirm that the user can produce a valid code for the newly-generated secret,
    /// then activate TOTP on the account. Backend: POST /api/auth/totp/verify-setup.
    /// - Parameters:
    ///   - secret:       the plain secret returned by setupTOTP()
    ///   - code:         the 6-digit code from the authenticator app
    ///   - recoveryCode: the recovery code returned by setupTOTP()
    func verifyTOTPSetup(secret: String, code: String, recoveryCode: String) async throws

    // Projects + sessions
    func fetchProjects() async throws -> [ProjectInfo]                     // /api/projects
    func fetchSessions() async throws -> [SessionInfo]                     // /api/sessions
    func fetchMessages(sessionId: String) async throws -> [ChatMessage]    // /api/projects/:projectId/sessions/:sessionId/messages
    /// Paginated message fetch. Returns the slice plus the server-side total
    /// and `hasMore` hint so the UI can decide whether to surface a
    /// "load older" affordance. Default limit is 200 (matches the server cap).
    func fetchMessagesPage(sessionId: String, limit: Int?, offset: Int) async throws -> (messages: [ChatMessage], total: Int, hasMore: Bool)

    // Claude Code slash commands (built-in + project + user)
    func fetchCommands(projectPath: String?) async throws -> [CommandInfo] // /api/commands/list

    // IM hub (subsystem 1). Default implementations below let stubs/tests opt out.
    func fetchImSync(since: Int) async throws -> ImSyncResponse                                   // /api/im/sync
    /// Cold-start cap variant: `recent > 0` returns only the last N messages per
    /// conversation with the cursor jumped to the server max. Default impl falls
    /// back to the full sync so existing conformers compile unchanged.
    func fetchImSync(since: Int, recent: Int) async throws -> ImSyncResponse
    func fetchImMessages(conversationId: String, anchor: Int?, numBefore: Int, numAfter: Int) async throws -> [ImMessageDTO]
    func postImRead(conversationId: String, deviceId: String, lastReadSeq: Int) async throws      // /api/im/conversations/:id/read
    /// Persist per-conversation state to the IM hub (server broadcasts an im:poke
    /// so the other devices re-sync). `note` is double-optional: `.some(nil)`
    /// clears it, `.some("x")` sets it, `nil` skips. Omitted flags are unchanged.
    func postImState(conversationId: String, isPinned: Bool?, isMuted: Bool?, isFolded: Bool?, isDeleted: Bool?, note: String??) async throws  // /api/im/conversations/:id/state
    func fetchImTranscript(conversationId: String, anchor: String?, numBefore: Int, numAfter: Int) async throws -> ImTranscriptPage  // /api/im/conversations/:id/transcript
    /// Lazy full-text of a server-truncated long message (P2). `messageId` is the
    /// message's serialized id. Default impl returns "" so stubs/tests compile.
    func fetchMessageContent(conversationId: String, messageId: String) async throws -> String  // GET /api/im/conversations/:id/messages/:messageId/content

    /// Send a chat message over plain HTTP (watchOS can't use WebSockets). Fire-and-
    /// forget on the server: the reply lands in the IM hub and is fetched via /sync.
    func sendImMessage(conversationId: String, text: String, projectPath: String?, clientMsgId: String?) async throws  // POST /api/im/conversations/:id/send

    /// Answer an interactive choice card over plain HTTP (watchOS has no chat WS).
    /// `answers` for AskUserQuestion (`{[question]: [labels]}`) OR `approve` for
    /// ExitPlanMode. The server flips the card to answered; the result re-syncs.
    func respondChoice(conversationId: String, requestId: String, answers: [String: [String]]?, approve: Bool?) async throws  // POST /api/im/conversations/:id/respond

    // Blacklisted project paths (server-synced). Sessions under a blacklisted
    // path are hidden on every device.
    func fetchBlacklist() async throws -> [String]                  // GET    /api/im/blacklist
    func addBlacklist(path: String) async throws                    // POST   /api/im/blacklist
    func removeBlacklist(path: String) async throws                 // DELETE /api/im/blacklist

    // Read-only usage / context displays. Default impls return nil so existing
    // conformers (stubs/tests) compile unchanged.
    func fetchClaudeUsageLimits(force: Bool) async throws -> ClaudeUsageLimits?    // GET /api/usage/claude-limits
    func fetchConversationContext(conversationId: String) async throws -> ConversationContext?  // GET /api/im/conversations/:id/context
    func fetchMedia(id: String, thumb: Bool) async throws -> Data                               // GET /api/im/media/:id
}

// Default IM implementations so existing conformers (e.g. StubAPIClient) compile
// unchanged; the real APIClient overrides these with networked versions.
public extension APIClientProtocol {
    func fetchImSync(since: Int) async throws -> ImSyncResponse {
        ImSyncResponse(messages: [], conversations: [], readCursors: [], cursor: since, hasMore: false)
    }
    func fetchImSync(since: Int, recent: Int) async throws -> ImSyncResponse {
        try await fetchImSync(since: since)
    }
    func fetchImMessages(conversationId: String, anchor: Int?, numBefore: Int, numAfter: Int) async throws -> [ImMessageDTO] { [] }
    func postImRead(conversationId: String, deviceId: String, lastReadSeq: Int) async throws {}
    func postImState(conversationId: String, isPinned: Bool?, isMuted: Bool?, isFolded: Bool?, isDeleted: Bool?, note: String??) async throws {}
    func fetchImTranscript(conversationId: String, anchor: String?, numBefore: Int, numAfter: Int) async throws -> ImTranscriptPage {
        ImTranscriptPage(entries: [], hasMoreBefore: false, hasMoreAfter: false)
    }
    func sendImMessage(conversationId: String, text: String, projectPath: String?, clientMsgId: String?) async throws {}
    func respondChoice(conversationId: String, requestId: String, answers: [String: [String]]?, approve: Bool?) async throws {}
    func fetchMessageContent(conversationId: String, messageId: String) async throws -> String { "" }
    /// Back-compat overload for callers that don't supply an idempotency key.
    func sendImMessage(conversationId: String, text: String, projectPath: String?) async throws {
        try await sendImMessage(conversationId: conversationId, text: text, projectPath: projectPath, clientMsgId: nil)
    }
    func fetchBlacklist() async throws -> [String] { [] }
    func addBlacklist(path: String) async throws {}
    func removeBlacklist(path: String) async throws {}
    func fetchClaudeUsageLimits(force: Bool) async throws -> ClaudeUsageLimits? { nil }
    func fetchConversationContext(conversationId: String) async throws -> ConversationContext? { nil }
    func fetchMedia(id: String, thumb: Bool) async throws -> Data { Data() }
}

public protocol ChatSocketProtocol: AnyObject, Sendable {
    /// Stream of server-pushed events. One subscriber owns it.
    var events: AsyncStream<ServerEvent> { get }
    func connect(baseURL: URL, token: String) async throws
    func send(_ event: ClientEvent) async throws
    func disconnect() async
    var isConnected: Bool { get async }
    /// Register a callback for ping→pong round-trip latency samples (ms).
    func setLatencyHandler(_ handler: @escaping @Sendable (Int) -> Void) async
    /// Fire an immediate ping to refresh the latency reading on demand.
    func ping() async
}

// ============================================================================
// Keychain (Agent A implements)
// ============================================================================

public protocol KeychainStoreProtocol: Sendable {
    /// Read the bearer token for a server profile. Returns nil if absent.
    func token(for profileId: UUID) -> String?
    /// Persist the bearer token for a server profile.
    func setToken(_ token: String?, for profileId: UUID)
}

// ============================================================================
// Server profile store (Agent A implements — small, no SwiftData needed)
// ============================================================================

public protocol ServerProfileStoreProtocol: Sendable {
    func list() -> [ServerProfile]
    func upsert(_ profile: ServerProfile)
    func remove(_ profileId: UUID)
    func mostRecent() -> ServerProfile?
}

// ============================================================================
// Storage / persistence (Agent B implements — backed by SwiftData)
//
// We keep the public surface as an actor protocol returning DTOs. Agent B is
// free to expose @Model types AND @Query helpers for UI to consume directly;
// this protocol is the minimum that the rest of the system can rely on.
// ============================================================================

public protocol StorageProtocol: Actor {
    // Sessions
    func upsertSession(_ session: SessionInfo) async
    func upsertSessions(_ sessions: [SessionInfo]) async
    func setHidden(sessionId: String, hidden: Bool) async
    func incrementUnread(sessionId: String) async
    func clearUnread(sessionId: String) async
    func listSessions(includingHidden: Bool) async -> [SessionInfo]
    func sessionExists(_ id: String) async -> Bool

    // Messages
    func upsertMessage(_ message: ChatMessage) async
    func appendStreamDelta(messageId: String, sessionId: String, delta: String) async
    func finalizeStreaming(messageId: String) async
    /// Clear the `isStreaming` flag on every message in a session (e.g. on
    /// `complete`/`error`) so a finished reply stops showing the loading dots.
    func finalizeStreaming(sessionId: String) async
    func messages(sessionId: String) async -> [ChatMessage]
    func latestMessage(sessionId: String) async -> ChatMessage?

    // Search
    func search(_ query: String) async -> SearchResults

    // Bookkeeping
    func reset() async

    // Extended operations (added by Agent B — additive only)
    /// Mark or clear the hasPendingApproval badge on a session.
    /// EventReducer calls this on `permissionRequest` / `permissionCancelled`.
    func setHasPendingApproval(sessionId: String, _ value: Bool) async

    /// Set a client-side nickname/note on a session. Pass nil to clear.
    func setNote(sessionId: String, _ note: String?) async
    /// Pin / unpin a session. Pinned sessions sort to the top.
    func setPinned(sessionId: String, _ pinned: Bool) async
    func setMuted(sessionId: String, _ muted: Bool) async
    /// Update a single message's delivery status (user-role messages only).
    func setSendStatus(messageId: String, _ status: SendStatus) async
    /// Update a single message's `sendStatus` to `.failed` and persist a reason.
    func setSendFailure(messageId: String, reason: String) async
    /// Flip every user-role message in a session from sending/sent/failed →
    /// delivered. Called when `.complete` arrives so the WeChat-style red
    /// exclamation disappears (also clears any previous failure reason so a
    /// retried session doesn't keep showing stale errors).
    func markUserMessagesDelivered(sessionId: String) async

    // IM hub conversation rows (subsystem 1). Exposed on the protocol so the UI
    // view-models can overlay server-synced pin/mute/note/fold onto the sidebar
    // and optimistically update it before an im:poke round-trips.
    //
    // NOTE: deliberately NO default implementation. The concrete `Storage`
    // witnesses are synchronous (actor-isolated); an async default here would
    // win overload resolution in `await storage.upsertImConversation(...)` calls
    // and silently no-op every IM write. Conformers implement these directly.
    func imConversations() async -> [ImConversationDTO]
    func upsertImConversation(_ conversation: ImConversationDTO) async
}
