import Foundation

// MARK: - Wire-format private types

/// The backend `POST /api/auth/login` returns `{success, user, token}` for
/// password-only accounts or `{requiresTotp: true, totpToken}` when 2FA is on.
private struct LoginWireResponse: Decodable {
    let token: String?
    let user: UserWire?
    let requiresTotp: Bool?   // camelCase — server/routes/auth.js line 145
    let totpToken: String?    // present when requiresTotp == true
    /// Server rotates the recovery code when the user logs in with one
    /// (auth.js:232-237) and returns the new one here. Must surface to UI.
    let newRecoveryCode: String?

    struct UserWire: Decodable {
        let id: Int
        let username: String
        let totpEnabled: Bool?
    }
}

private struct AuthStatusWireResponse: Decodable {
    let needsSetup: Bool?
    let isAuthenticated: Bool?
    let devBypass: Bool?
}

private struct CurrentUserWireResponse: Decodable {
    let user: User
}

/// Wire type matching the real backend shape from `getProjectsWithSessions()`:
/// `{ projectId, path, displayName, fullPath, isStarred, sessions, sessionMeta }`
/// We only need the top-level project fields; nested sessions are fetched separately
/// via `/api/sessions/active`.
private struct ProjectWire: Decodable {
    let projectId: String
    let path: String
    let displayName: String
    let fullPath: String?
    let isStarred: Bool?
    // `sessions` and `sessionMeta` are intentionally ignored here.
}

// MARK: - APIClient

/// URLSession-backed implementation of `APIClientProtocol`.
///
/// Thread-safety: implemented as an `actor`.
/// - Injects `Authorization: Bearer <token>` on every request.
/// - Handles `X-Refreshed-Token` response header by updating the stored token.
/// - Stores the pending TOTP token after a `requirestotp` login response so that
///   `AuthCoordinator` can retrieve it via `pendingTotpToken`.
public actor APIClient: APIClientProtocol {

    // MARK: - State

    var baseURL: URL
    var token: String?
    /// Stored by `login(...)` when the server responds with `requirestotp: true`.
    /// `AuthCoordinator` reads this before calling `loginWithTOTPToken`.
    private(set) var pendingTotpToken: String?

    let session: URLSession

    // MARK: - Decoders / encoders

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let isoFull = ISO8601DateFormatter()
            isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFull.date(from: string) { return date }
            let isoBasic = ISO8601DateFormatter()
            isoBasic.formatOptions = [.withInternetDateTime]
            if let date = isoBasic.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Cannot parse date string: \(string)")
        }
        return d
    }()

    // MARK: - Init

    public init(baseURL: URL = URL(string: "http://localhost:3000")!,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - APIClientProtocol: configuration

    public func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    // MARK: - APIClientProtocol: Auth

    public func authStatus() async throws -> Bool {
        let data = try await get(path: "/api/auth/status")
        let resp = try decoder.decode(AuthStatusWireResponse.self, from: data)
        return !(resp.needsSetup ?? true)
    }

    public func devAuthBypassed() async -> Bool {
        do {
            let data = try await get(path: "/api/auth/status")
            let resp = try decoder.decode(AuthStatusWireResponse.self, from: data)
            return resp.devBypass ?? false
        } catch {
            return false
        }
    }

    public func login(username: String, password: String) async throws -> LoginResponse {
        let body: [String: Any] = ["username": username, "password": password]
        let data = try await post(path: "/api/auth/login", jsonObject: body)
        let wire = try decoder.decode(LoginWireResponse.self, from: data)

        // Stash the totpToken so AuthCoordinator can retrieve it.
        self.pendingTotpToken = wire.totpToken

        let user = wire.user.map { u in
            User(id: u.id, username: u.username, totpEnabled: u.totpEnabled)
        }
        return LoginResponse(
            token: wire.token,
            user: user,
            requiresTotp: wire.requiresTotp,
            totpToken: wire.totpToken,
            newRecoveryCode: wire.newRecoveryCode
        )
    }

    /// Second-factor TOTP login. `totpToken` is the short-lived JWT returned by
    /// the first `/login` response when 2FA is required.
    /// Uses `performPreservingHTTPStatus` so that 401/429 surface as
    /// `.httpStatus(code:body:)` (so callers can map to "wrong code" / "locked").
    public func loginWithTOTP(totpToken: String, code: String) async throws -> LoginResponse {
        let jsonBody: [String: Any] = ["totpToken": totpToken, "code": code]
        let bodyData = try JSONSerialization.data(withJSONObject: jsonBody)
        let req = try buildRequest(method: "POST", path: "/api/auth/login/totp", body: bodyData)
        let data = try await performPreservingHTTPStatus(req)
        let wire = try decoder.decode(LoginWireResponse.self, from: data)
        let user = wire.user.map { u in
            User(id: u.id, username: u.username, totpEnabled: u.totpEnabled)
        }
        return LoginResponse(token: wire.token, user: user, newRecoveryCode: wire.newRecoveryCode)
    }

    public func currentUser() async throws -> User {
        let data = try await get(path: "/api/auth/user")
        let resp = try decoder.decode(CurrentUserWireResponse.self, from: data)
        return resp.user
    }

    public func logout() async throws {
        _ = try await post(path: "/api/auth/logout", jsonObject: [:])
    }

    /// POST /api/auth/totp/setup — generates a new TOTP secret.
    /// Returns (secret, otpauthUri, recoveryCode).
    public func setupTOTP() async throws -> (secret: String, provisioningUri: String, recoveryCode: String) {
        struct SetupResponse: Decodable {
            let secret: String
            let otpauthUri: String
            let recoveryCode: String
        }
        let data = try await post(path: "/api/auth/totp/setup", jsonObject: [:])
        let resp = try decoder.decode(SetupResponse.self, from: data)
        return (secret: resp.secret, provisioningUri: resp.otpauthUri, recoveryCode: resp.recoveryCode)
    }

    /// POST /api/auth/totp/verify-setup — activates TOTP after user confirms the code.
    public func verifyTOTPSetup(secret: String, code: String, recoveryCode: String) async throws {
        let body: [String: Any] = ["secret": secret, "code": code, "recoveryCode": recoveryCode]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let req = try buildRequest(method: "POST", path: "/api/auth/totp/verify-setup", body: bodyData)
        _ = try await performPreservingHTTPStatus(req)
    }

    // MARK: - APIClientProtocol: Projects + Sessions

    public func fetchProjects() async throws -> [ProjectInfo] {
        let data = try await get(path: "/api/projects")
        let wires = try decoder.decode([ProjectWire].self, from: data)
        return wires.map { w in
            ProjectInfo(
                id: w.projectId,
                displayName: w.displayName,
                path: w.path,
                fullPath: w.fullPath
            )
        }
    }

    /// Create (or reactivate) a project/contact. Mirrors the web
    /// `POST /api/projects/create-project` flow. Returns the created project.
    public func createProject(path: String, customName: String?) async throws -> ProjectInfo {
        var body: [String: Any] = ["path": path]
        if let customName, !customName.isEmpty { body["customName"] = customName }
        let data = try await post(path: "/api/projects/create-project", jsonObject: body)
        struct CreateResponse: Decodable {
            let project: ProjectWire
        }
        let resp = try decoder.decode(CreateResponse.self, from: data)
        let w = resp.project
        return ProjectInfo(id: w.projectId, displayName: w.displayName, path: w.path, fullPath: w.fullPath)
    }

    public func fetchSessions() async throws -> [SessionInfo] {
        let data = try await get(path: "/api/sessions/active")
        struct ActiveResponse: Decodable {
            struct Entry: Decodable {
                let id: String
                let title: String?
                let project: String?
                let cwd: String?
                let mtime: Double?
                let projectId: String?
            }
            let live: [Entry]
        }
        let resp = try decoder.decode(ActiveResponse.self, from: data)
        return resp.live.map { e in
            SessionInfo(
                id: e.id,
                projectPath: e.cwd ?? e.project ?? "",
                title: e.title,
                lastActivityAt: e.mtime.map { Date(timeIntervalSince1970: $0 / 1000) },
                isActive: true
            )
        }
    }

    public func fetchCommands(projectPath: String?) async throws -> [CommandInfo] {
        // POST /api/commands/list — body: { projectPath?: string }
        // Returns: { builtIn: [...], custom: [...], count: int }
        var body: [String: Any] = [:]
        if let p = projectPath { body["projectPath"] = p }
        let data = try await post(path: "/api/commands/list", jsonObject: body)

        struct Wrapper: Decodable {
            struct CmdWire: Decodable {
                let name: String
                let description: String?
                let namespace: String?
            }
            let builtIn: [CmdWire]?
            let custom: [CmdWire]?
        }
        let wire = try decoder.decode(Wrapper.self, from: data)
        let combined = (wire.builtIn ?? []) + (wire.custom ?? [])
        let serverCmds = combined.map { CommandInfo(name: $0.name,
                                                    description: $0.description ?? "",
                                                    namespace: $0.namespace ?? "unknown") }

        // Supplement with Claude Code built-ins the server's list misses,
        // and fetch skills (which are also surfaced as slash commands).
        let extras = builtInClaudeCodeCommands(currentNames: Set(serverCmds.map(\.name)))
        let skills = (try? await fetchClaudeSkills(workspacePath: projectPath)) ?? []
        return serverCmds + extras + skills
    }

    /// Hardcoded fallback: commands shipped with Claude Code but not always
    /// returned by `/api/commands/list`.
    private func builtInClaudeCodeCommands(currentNames: Set<String>) -> [CommandInfo] {
        let candidates: [(String, String)] = [
            ("/compact",        "Compact the conversation context"),
            ("/resume",         "Resume a previous session"),
            ("/init",           "Initialize CLAUDE.md for this project"),
            ("/bug",            "Report a bug to Anthropic"),
            ("/review",         "Review the current diff or PR"),
            ("/add-dir",        "Add a directory to the workspace"),
            ("/agents",         "Manage subagents"),
            ("/hooks",          "Manage hooks"),
            ("/mcp",            "Manage MCP servers"),
            ("/pr-comments",    "Show PR comments"),
            ("/vim",            "Toggle vim mode in composer"),
            ("/export",         "Export the conversation"),
            ("/diff",           "Show the current diff"),
            ("/quit",           "Quit Claude Code"),
            ("/login",          "Switch accounts"),
            ("/logout",         "Sign out of Claude Code"),
            ("/doctor",         "Diagnose installation problems"),
            ("/terminal-setup", "Configure terminal integration"),
        ]
        return candidates
            .filter { !currentNames.contains($0.0) }
            .map { CommandInfo(name: $0.0, description: $0.1, namespace: "builtin") }
    }

    /// Skills are surfaced as slash commands (e.g. `/skill-name`).
    /// GET /api/providers/claude/skills?workspacePath=… → { success, data: { skills: [...] } }
    private func fetchClaudeSkills(workspacePath: String?) async throws -> [CommandInfo] {
        var path = "/api/providers/claude/skills"
        if let p = workspacePath, let encoded = p.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?workspacePath=\(encoded)"
        }
        let data = try await get(path: path)
        struct Wrapper: Decodable {
            struct DataPayload: Decodable {
                struct Skill: Decodable {
                    let command: String?
                    let name: String?
                    let description: String?
                }
                let skills: [Skill]?
            }
            let data: DataPayload?
        }
        let wire = try decoder.decode(Wrapper.self, from: data)
        return (wire.data?.skills ?? []).compactMap { s in
            let name = s.command ?? s.name.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? ""
            guard !name.isEmpty else { return nil }
            return CommandInfo(name: name,
                               description: s.description ?? "",
                               namespace: "skill")
        }
    }

    public func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        // Default page: most recent 200 messages. Large sessions (>10k turns)
        // used to OOM the decoder + lock UI for seconds before this cap.
        // Use `fetchMessagesPage(sessionId:limit:offset:)` for paginated access.
        return try await fetchMessagesPage(sessionId: sessionId, limit: 200, offset: 0).messages
    }

    /// Paginated message fetch. The server (provider.routes.ts:368-401) accepts
    /// `?limit=N&offset=M` and returns `{messages, total, hasMore, offset, limit}`.
    public func fetchMessagesPage(
        sessionId: String,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> (messages: [ChatMessage], total: Int, hasMore: Bool) {
        let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        var path = "/api/providers/sessions/\(encodedId)/messages"
        var query: [String] = []
        if let limit { query.append("limit=\(limit)") }
        if offset > 0 { query.append("offset=\(offset)") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        let data = try await get(path: path)

        // Backend `sessionsService.fetchHistory` returns
        //   { messages: NormalizedMessage[], total, hasMore, offset, limit }
        // (not wrapped in `{success, data}`). NormalizedMessage uses a `kind`
        // discriminator instead of `role`.
        struct Wrapper: Decodable {
            let messages: [RawMessage]?
            let total: Int?
            let hasMore: Bool?
        }
        struct RawMessage: Decodable {
            let id: String?
            let sessionId: String?
            let kind: String?
            let role: String?           // "user" | "assistant", present when kind == "text"
            let content: String?
            let timestamp: String?
            // Tool fields (when kind == "tool_use" / "tool_result")
            let toolName: String?
            let toolId: String?
            let toolInput: AnyDecodable?
            let toolResult: ToolResultWire?

            struct ToolResultWire: Decodable {
                let content: String?
                let isError: Bool?
            }
        }
        struct AnyDecodable: Decodable {
            let raw: Any
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { raw = s }
                else if let d = try? c.decode([String: AnyDecodable].self) {
                    raw = d.mapValues { $0.raw }
                }
                else if let a = try? c.decode([AnyDecodable].self) {
                    raw = a.map(\.raw)
                }
                else { raw = "" }
            }
        }

        let wrapper = try decoder.decode(Wrapper.self, from: data)
        let rawMsgs = wrapper.messages ?? []
        let total = wrapper.total ?? rawMsgs.count
        let hasMore = wrapper.hasMore ?? false

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        let messages: [ChatMessage] = rawMsgs.compactMap { raw -> ChatMessage? in
            guard let id = raw.id else { return nil }
            // Map backend MessageKind + role → our MessageRole.
            // Skip metadata kinds (status / complete / stream_delta / etc.) that
            // shouldn't render as chat content.
            let role: MessageRole
            switch raw.kind {
            case "text":
                role = (raw.role == "user") ? .user : .assistant
            case "tool_use", "tool_result":
                role = .tool
            case "thinking":
                role = .assistant
            case "error":
                role = .system
            case "status", "complete", "stream_delta", "stream_end",
                 "permission_request", "permission_cancelled", "session_created":
                return nil   // metadata events, not chat bubbles
            default:
                role = .assistant
            }
            var createdAt = Date()
            if let ts = raw.timestamp {
                createdAt = isoFull.date(from: ts) ?? isoBasic.date(from: ts) ?? Date()
            }
            var toolUse: ToolInvocation?
            if role == .tool {
                let inputStr: String
                if let any = raw.toolInput?.raw {
                    inputStr = (try? String(data: JSONSerialization.data(withJSONObject: any), encoding: .utf8)) ?? ""
                } else {
                    inputStr = ""
                }
                toolUse = ToolInvocation(
                    name: raw.toolName ?? "",
                    input: inputStr,
                    output: raw.toolResult?.content,
                    requestId: raw.toolId
                )
            }
            return ChatMessage(
                id: id,
                sessionId: raw.sessionId ?? sessionId,
                role: role,
                content: raw.content ?? "",
                toolUse: toolUse,
                createdAt: createdAt
            )
        }
        return (messages: messages, total: total, hasMore: hasMore)
    }

    // MARK: - HTTP primitives

    func get(path: String) async throws -> Data {
        let req = try buildRequest(method: "GET", path: path, body: nil)
        return try await perform(req)
    }

    @discardableResult
    func post(path: String, jsonObject: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: jsonObject)
        let req = try buildRequest(method: "POST", path: path, body: body)
        return try await perform(req)
    }

    func buildRequest(method: String, path: String, body: Data?) throws -> URLRequest {
        // Combine baseURL with path, tolerating whether baseURL has a trailing slash.
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard let url = URL(string: base + path) else {
            throw ChatKitError.unsupportedURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Bound every REST call so a stalled request can't pin a loading state
        // ("正在同步…" / 全文 spinner / transcript) open indefinitely — it fails
        // with a timeout the caller can recover from instead of hanging.
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    /// Perform an HTTP request, mapping 401 to `ChatKitError.notAuthenticated`.
    /// Other non-2xx codes become `ChatKitError.httpStatus`.
    func perform(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await _fetch(request)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 {
                throw ChatKitError.notAuthenticated
            }
            throw ChatKitError.httpStatus(code: http.statusCode, body: body)
        }
        return data
    }

    /// Perform an HTTP request, always converting non-2xx to `ChatKitError.httpStatus`
    /// (does NOT special-case 401 → notAuthenticated).  Used by TOTP endpoints where
    /// 401 means "wrong code" not "unauthenticated session".
    func performPreservingHTTPStatus(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await _fetch(request)
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatKitError.httpStatus(code: http.statusCode, body: body)
        }
        return data
    }

    /// Low-level fetch: makes the network request, handles token refresh header,
    /// returns (data, HTTPURLResponse).
    private func _fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatKitError.other(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatKitError.other("Non-HTTP response")
        }

        // Handle token refresh header
        if let refreshed = http.value(forHTTPHeaderField: "X-Refreshed-Token"), !refreshed.isEmpty {
            self.token = refreshed
        }

        return (data, http)
    }

    // MARK: - IM hub endpoints (subsystem 1)

    private func encodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    public func fetchImSync(since: Int) async throws -> ImSyncResponse {
        try await fetchImSync(since: since, recent: 0)
    }

    /// `recent > 0` triggers the server cold-start cap: only the last `recent`
    /// messages per conversation, with the cursor jumped to the server max rev.
    public func fetchImSync(since: Int, recent: Int) async throws -> ImSyncResponse {
        var path = "/api/im/sync?since=\(since)"
        if recent > 0 { path += "&recent=\(recent)" }
        let req = try buildRequest(method: "GET", path: path, body: nil)
        let data = try await perform(req)
        return try decoder.decode(ImSyncResponse.self, from: data)
    }

    public func fetchImMessages(conversationId: String, anchor: Int?, numBefore: Int, numAfter: Int) async throws -> [ImMessageDTO] {
        var path = "/api/im/conversations/\(encodePathSegment(conversationId))/messages?numBefore=\(numBefore)&numAfter=\(numAfter)"
        if let anchor { path += "&anchor=\(anchor)" }
        let req = try buildRequest(method: "GET", path: path, body: nil)
        let data = try await perform(req)
        struct Wrapper: Decodable { let messages: [ImMessageDTO] }
        return try decoder.decode(Wrapper.self, from: data).messages
    }

    public func postImRead(conversationId: String, deviceId: String, lastReadSeq: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "lastReadSeq": lastReadSeq])
        let req = try buildRequest(method: "POST", path: "/api/im/conversations/\(encodePathSegment(conversationId))/read", body: body)
        _ = try await perform(req)
    }

    public func postImState(conversationId: String, isPinned: Bool? = nil, isMuted: Bool? = nil,
                            isFolded: Bool? = nil, isDeleted: Bool? = nil, note: String?? = nil) async throws {
        var obj: [String: Any] = [:]
        if let isPinned { obj["isPinned"] = isPinned }
        if let isMuted { obj["isMuted"] = isMuted }
        if let isFolded { obj["isFolded"] = isFolded }
        if let isDeleted { obj["isDeleted"] = isDeleted }
        // note is double-optional: .some(nil) clears it, .some("x") sets it, nil skips.
        if let note { obj["note"] = note ?? NSNull() }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let req = try buildRequest(method: "POST", path: "/api/im/conversations/\(encodePathSegment(conversationId))/state", body: body)
        _ = try await perform(req)
    }

    // MARK: - Blacklist (server-synced)

    public func fetchBlacklist() async throws -> [String] {
        let data = try await get(path: "/api/im/blacklist")
        struct Resp: Decodable { let paths: [String] }
        return try decoder.decode(Resp.self, from: data).paths
    }

    public func addBlacklist(path: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        let req = try buildRequest(method: "POST", path: "/api/im/blacklist", body: body)
        _ = try await perform(req)
    }

    public func removeBlacklist(path: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        let req = try buildRequest(method: "DELETE", path: "/api/im/blacklist", body: body)
        _ = try await perform(req)
    }

    public func fetchImTranscript(conversationId: String, anchor: String?, numBefore: Int, numAfter: Int) async throws -> ImTranscriptPage {
        var path = "/api/im/conversations/\(encodePathSegment(conversationId))/transcript?numBefore=\(numBefore)&numAfter=\(numAfter)"
        if let anchor { path += "&anchor=\(encodePathSegment(anchor))" }
        let req = try buildRequest(method: "GET", path: path, body: nil)
        let data = try await perform(req)
        return try decoder.decode(ImTranscriptPage.self, from: data)
    }

    /// Send a chat message over plain HTTP (watchOS can't use WebSockets). The
    /// server queues it into the IM hub (202 {"ok":true}) and the reply is later
    /// fetched via /sync. Any 2xx is success; non-2xx throws.
    public func sendImMessage(conversationId: String, text: String, projectPath: String?, clientMsgId: String?) async throws {
        var obj: [String: Any] = ["text": text]
        obj["projectPath"] = projectPath ?? NSNull()
        // Idempotency key: a resend with the same id is a server-side no-op.
        if let clientMsgId, !clientMsgId.isEmpty { obj["clientMsgId"] = clientMsgId }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let req = try buildRequest(method: "POST", path: "/api/im/conversations/\(encodePathSegment(conversationId))/send", body: body)
        _ = try await perform(req)
    }

    /// Answer an interactive choice card over plain HTTP (watchOS has no chat WS).
    /// POST /api/im/conversations/:id/respond — body carries `answers` (for
    /// AskUserQuestion) OR `approve` (for ExitPlanMode), always with `requestId`.
    public func respondChoice(conversationId: String, requestId: String,
                              answers: [String: [String]]?, approve: Bool?) async throws {
        var obj: [String: Any] = ["requestId": requestId]
        if let answers {
            obj["answers"] = answers
        } else if let approve {
            obj["approve"] = approve
        }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let req = try buildRequest(method: "POST", path: "/api/im/conversations/\(encodePathSegment(conversationId))/respond", body: body)
        _ = try await perform(req)
    }

    /// GET /api/im/conversations/:id/messages/:messageId/content — the full,
    /// un-truncated body of a long message (server P2 lazy full-text endpoint).
    /// `messageId` is the message's serialized id (== the sourceId from /sync).
    public func fetchMessageContent(conversationId: String, messageId: String) async throws -> String {
        let path = "/api/im/conversations/\(encodePathSegment(conversationId))/messages/\(encodePathSegment(messageId))/content"
        let req = try buildRequest(method: "GET", path: path, body: nil)
        let data = try await perform(req)
        struct Wrapper: Decodable { let content: String }
        return try decoder.decode(Wrapper.self, from: data).content
    }

    // MARK: - Usage / context (read-only displays)

    /// GET /api/usage/claude-limits — always HTTP 200 with a `ClaudeUsageLimits`
    /// object; its `fiveHour` / `sevenDay` fields may individually be null.
    /// Pass `force` for a manual refresh (server floors upstream calls at 5min).
    public func fetchClaudeUsageLimits(force: Bool = false) async throws -> ClaudeUsageLimits? {
        let data = try await get(path: "/api/usage/claude-limits" + (force ? "?force=1" : ""))
        // Tolerate a literal `null` body just in case.
        if isJSONNull(data) { return nil }
        return try decoder.decode(ClaudeUsageLimits.self, from: data)
    }

    /// GET /api/im/media/:id — raw bytes of an assistant-sent image
    /// (kind:'image'). `id` is the `<hex>.<ext>` media id from the message.
    /// `thumb` requests the small JPEG thumbnail (falls back to the original
    /// server-side if none exists).
    public func fetchMedia(id: String, thumb: Bool = false) async throws -> Data {
        try await get(path: "/api/im/media/\(encodePathSegment(id))" + (thumb ? "?thumb=1" : ""))
    }

    /// GET /api/im/conversations/:id/context — `ConversationContext` OR a literal
    /// JSON `null` (HTTP 200) when no data is available yet → nil.
    public func fetchConversationContext(conversationId: String) async throws -> ConversationContext? {
        let data = try await get(path: "/api/im/conversations/\(encodePathSegment(conversationId))/context")
        if isJSONNull(data) { return nil }
        return try decoder.decode(ConversationContext.self, from: data)
    }

    /// True when the response body is an empty/whitespace payload or a literal
    /// JSON `null` token, so we can map it to a nil optional instead of throwing.
    private func isJSONNull(_ data: Data) -> Bool {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "null"
    }
}
