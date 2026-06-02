import Foundation

/// Events the server sends to the client over the chat WebSocket.
///
/// The backend uses two kinds of envelopes:
/// 1. Normalized messages keyed by `kind` (via `server/shared/utils.ts#createNormalizedMessage`)
/// 2. Ad-hoc frames keyed by `type` (e.g. `session-status`, `error`, `active-sessions`)
///
/// Agent A's `ChatSocket` decodes either envelope into a `ServerEvent`. New kinds
/// not enumerated below decode to `.raw(json:)` and are surfaced for inspection.
public enum ServerEvent: Sendable {
    case sessionCreated(sessionId: String)
    case assistantText(sessionId: String, messageId: String, text: String, isDelta: Bool)
    case toolUse(sessionId: String, messageId: String, name: String, input: String)
    case toolResult(sessionId: String, toolUseId: String, output: String, isError: Bool)
    case permissionRequest(sessionId: String, requestId: String, toolName: String, input: String, timeoutMs: Int?)
    case permissionCancelled(sessionId: String, requestId: String, reason: String?)
    case status(sessionId: String, text: String, tokenBudget: Int?)
    case complete(sessionId: String, exitCode: Int, aborted: Bool, isNewSession: Bool)
    case sessionStatus(sessionId: String, isProcessing: Bool)
    case error(sessionId: String?, message: String)
    /// Synthesized by ChatSocket (never decoded from the wire) — connection lifecycle.
    case connection(ConnectionState)
    // IM hub frames (subsystem 1). `type` envelope: im:message / im:read / im:poke.
    case imMessage(conversationId: String, message: ImMessageDTO)
    case imRead(conversationId: String, deviceId: String, lastReadSeq: Int)
    case imPoke(since: Int)
    /// Throttled progress for an in-flight IM turn. `conversationId == sessionId`.
    /// A terminal `isProcessing:false` is always sent at turn end.
    case imStatus(conversationId: String, isProcessing: Bool, toolCount: Int, currentTool: String?)
    case raw(kind: String?, type: String?, payload: Data)
}

/// Tool restriction + permission overrides per claude-command. Mirrors the
/// shape the backend reads at `server/claude-sdk.js:172-176`. All fields
/// are optional — omit a field to let the backend use its default. The web
/// client always sends a fully-populated object; we follow suit when the
/// UI has a value to express but allow `nil` for "use server default".
public struct ClaudeToolsSettings: Sendable {
    public var allowedTools: [String]
    public var disallowedTools: [String]
    public var skipPermissions: Bool

    public init(allowedTools: [String] = [], disallowedTools: [String] = [], skipPermissions: Bool = false) {
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.skipPermissions = skipPermissions
    }
}

/// Valid `permissionMode` values per Claude Agent SDK. Sending anything else
/// makes the SDK throw (this is what bit us with `"ask"`). Use `nil` to omit
/// the field entirely — the SDK then uses its built-in default.
public enum ClaudePermissionMode: String, Sendable {
    case acceptEdits
    case bypassPermissions
    case plan
}

/// One image attachment dragged into the composer. The backend expects a
/// `data:` URI (server/claude-sdk.js:361 regex), so we always normalise
/// raw base64 to that form. `filename` is purely for UI display.
public struct PendingImage: Sendable, Hashable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    /// Full data URI: `data:image/png;base64,XXXX`.
    public let dataURI: String

    public init(id: String = UUID().uuidString,
                filename: String,
                mimeType: String,
                dataURI: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.dataURI = dataURI
    }

    /// Convenience: build from raw base64 + mime type.
    public init(filename: String, mimeType: String, base64: String) {
        self.id = UUID().uuidString
        self.filename = filename
        self.mimeType = mimeType
        self.dataURI = "data:\(mimeType);base64,\(base64)"
    }
}

/// Frames the client sends to the server. Match `server/modules/websocket/services/chat-websocket.service.ts`.
public enum ClientEvent: Sendable {
    case claudeCommand(
        prompt: String,
        sessionId: String?,
        projectPath: String?,
        modelId: String?,
        resume: Bool,
        toolsSettings: ClaudeToolsSettings? = nil,
        permissionMode: ClaudePermissionMode? = nil,
        images: [PendingImage]? = nil,
        // Opt-in tool-approval behaviour (IM clients). When set, the server
        // waits `approvalTimeoutMs` for the user, then auto-executes if
        // `autoApproveOnTimeout` is true instead of denying.
        approvalTimeoutMs: Int? = nil,
        autoApproveOnTimeout: Bool? = nil,
        // Idempotency key for "reliable send". The client reuses its optimistic
        // pending message id; a resend after a lost ack is deduped server-side
        // (server/claude-sdk.js) instead of double-invoking Claude.
        clientMsgId: String? = nil
    )
    case abortSession(sessionId: String)
    case toolApprovalResponse(
        requestId: String,
        allow: Bool,
        updatedInput: String? = nil,
        message: String? = nil,
        rememberEntry: String? = nil
    )
    case checkSessionStatus(sessionId: String)
    case getPendingPermissions(sessionId: String)
    case getActiveSessions

    /// Answer an interactive IM choice card (红包-style poll). Wire payload is the
    /// server's `claude-permission-response`:
    ///   • AskUserQuestion → `{requestId, answers: {"<question>": ["<label>",…]}}`
    ///   • ExitPlanMode    → `{requestId, approve: <bool>}`
    /// Exactly one of `answers` / `approve` is set per the flavor.
    case imChoiceAnswer(requestId: String, answers: [String: [String]]?, approve: Bool?)

    /// Serialize to the JSON payload the server expects. Implementation lives in
    /// `Network/ClientEvent+Wire.swift` so the public enum stays UI-friendly.
    public func wirePayload() -> [String: Any] {
        switch self {
        case let .claudeCommand(prompt, sessionId, projectPath, modelId, resume, toolsSettings, permissionMode, images, approvalTimeoutMs, autoApproveOnTimeout, clientMsgId):
            // Web client always populates these even with defaults; backend
            // tolerates omission (server/claude-sdk.js:172-176 supplies the
            // same defaults). Only send `permissionMode` when the user has
            // explicitly chosen one — Claude SDK rejects unknown values.
            var options: [String: Any] = [:]
            if let sessionId { options["sessionId"] = sessionId }
            if let projectPath {
                options["projectPath"] = projectPath
                options["cwd"] = projectPath
            }
            if let modelId { options["model"] = modelId }
            // The backend reads `sessionId` directly to set SDK.resume, so
            // this boolean is purely informational — but the web client sends
            // it, so we mirror.
            options["resume"] = (sessionId != nil) && resume
            if let toolsSettings {
                options["toolsSettings"] = [
                    "allowedTools": toolsSettings.allowedTools,
                    "disallowedTools": toolsSettings.disallowedTools,
                    "skipPermissions": toolsSettings.skipPermissions,
                ]
            }
            if let permissionMode {
                options["permissionMode"] = permissionMode.rawValue
            }
            if let images, !images.isEmpty {
                // Match the shape server/claude-sdk.js:361 parses: each entry
                // is `{ data: "data:image/...;base64,..." }`.
                options["images"] = images.map { ["data": $0.dataURI, "name": $0.filename] }
            }
            if let approvalTimeoutMs { options["approvalTimeoutMs"] = approvalTimeoutMs }
            if let autoApproveOnTimeout { options["autoApproveOnTimeout"] = autoApproveOnTimeout }
            if let clientMsgId, !clientMsgId.isEmpty { options["clientMsgId"] = clientMsgId }
            return ["type": "claude-command", "command": prompt, "options": options]

        case let .abortSession(sessionId):
            return ["type": "abort-session", "sessionId": sessionId]

        case let .toolApprovalResponse(requestId, allow, updatedInput, message, rememberEntry):
            var payload: [String: Any] = [
                "type": "claude-permission-response",
                "requestId": requestId,
                "allow": allow,
            ]
            if let updatedInput { payload["updatedInput"] = updatedInput }
            if let message { payload["message"] = message }
            // `rememberEntry` is what makes "always allow" / "always deny"
            // stick — server appends it to allowedTools / disallowedTools
            // (claude-sdk.js:603-607).
            if let rememberEntry { payload["rememberEntry"] = rememberEntry }
            return payload

        case let .checkSessionStatus(sessionId):
            return ["type": "check-session-status", "sessionId": sessionId]

        case let .getPendingPermissions(sessionId):
            return ["type": "get-pending-permissions", "sessionId": sessionId]

        case .getActiveSessions:
            return ["type": "get-active-sessions"]

        case let .imChoiceAnswer(requestId, answers, approve):
            var payload: [String: Any] = [
                "type": "claude-permission-response",
                "requestId": requestId,
            ]
            if let answers {
                payload["answers"] = answers
            } else if let approve {
                payload["approve"] = approve
            }
            return payload
        }
    }
}

// MARK: - ServerEvent JSON decoding (added by Agent A)

/// Convert an arbitrary JSON value (string, dict, array) to its string representation.
private func _jsonValueToString(_ value: Any?) -> String {
    guard let value else { return "" }
    if let s = value as? String { return s }
    // Try to serialize objects / arrays back to JSON
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: value)
}

private extension String {
    /// Returns self if non-empty, otherwise nil.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ServerEvent {
    /// Decode a raw WebSocket text frame (already parsed to `[String: Any]`) into
    /// a `ServerEvent`.  Tries both the `kind` envelope (normalized) and the `type`
    /// envelope (ad-hoc).
    static func decode(from json: [String: Any], rawData: Data) -> ServerEvent {
        // Determine the dispatch key: prefer `kind`, fall back to `type`.
        let kind  = json["kind"]  as? String
        let type_ = json["type"]  as? String
        let sessionId = (json["sessionId"] as? String) ?? ""

        switch kind ?? type_ ?? "" {

        // ── Normalized `kind` frames ──────────────────────────────────────────

        case "session_created":
            let sid = (json["newSessionId"] as? String)
                   ?? (json["sessionId"] as? String)
                   ?? ""
            return .sessionCreated(sessionId: sid)

        case "stream_delta":
            let messageId = (json["id"] as? String) ?? ""
            let text = (json["content"] as? String) ?? (json["text"] as? String) ?? ""
            return .assistantText(sessionId: sessionId, messageId: messageId, text: text, isDelta: true)

        case "stream_end":
            let messageId = (json["id"] as? String) ?? ""
            return .assistantText(sessionId: sessionId, messageId: messageId, text: "", isDelta: false)

        case "assistant", "text":
            // Some adapters emit kind:"assistant" for full assistant messages
            let messageId = (json["id"] as? String) ?? ""
            let text = (json["content"] as? String) ?? (json["text"] as? String) ?? ""
            let isDelta = (json["isDelta"] as? Bool) ?? false
            return .assistantText(sessionId: sessionId, messageId: messageId, text: text, isDelta: isDelta)

        case "tool_use":
            let messageId = (json["id"] as? String) ?? (json["toolId"] as? String) ?? ""
            let name  = (json["toolName"] as? String) ?? ""
            let input = _jsonValueToString(json["toolInput"]) .nonEmpty ?? _jsonValueToString(json["input"])
            return .toolUse(sessionId: sessionId, messageId: messageId, name: name, input: input)

        case "tool_result":
            let toolUseId = (json["toolId"] as? String) ?? (json["id"] as? String) ?? ""
            let resultObj = json["toolResult"] as? [String: Any]
            let output = (resultObj?["content"] as? String) ?? (json["content"] as? String) ?? ""
            let isError = (resultObj?["isError"] as? Bool) ?? (json["isError"] as? Bool) ?? false
            return .toolResult(sessionId: sessionId, toolUseId: toolUseId, output: output, isError: isError)

        case "permission_request":
            let requestId = (json["requestId"] as? String) ?? ""
            let toolName  = (json["toolName"] as? String) ?? ""
            let input = _jsonValueToString(json["input"])
            let timeoutMs = json["timeoutMs"] as? Int
            return .permissionRequest(sessionId: sessionId, requestId: requestId,
                                      toolName: toolName, input: input, timeoutMs: timeoutMs)

        case "permission_cancelled":
            let requestId = (json["requestId"] as? String) ?? ""
            let reason    = json["reason"] as? String
            return .permissionCancelled(sessionId: sessionId, requestId: requestId, reason: reason)

        case "status":
            let text: String
            if let t = json["text"] as? String { text = t }
            else if let t = json["status"] as? String { text = t }
            else { text = "" }
            let tokenBudget: Int?
            if let tb = json["tokenBudget"] as? [String: Any] {
                tokenBudget = tb["remainingTokens"] as? Int ?? tb["remaining"] as? Int
            } else {
                tokenBudget = json["tokenBudget"] as? Int
            }
            return .status(sessionId: sessionId, text: text, tokenBudget: tokenBudget)

        case "complete":
            let exitCode    = (json["exitCode"] as? Int) ?? 0
            let aborted     = (json["aborted"] as? Bool) ?? false
            let isNewSession = (json["isNewSession"] as? Bool) ?? false
            return .complete(sessionId: sessionId, exitCode: exitCode,
                             aborted: aborted, isNewSession: isNewSession)

        // ── Ad-hoc `type` frames ─────────────────────────────────────────────

        case "session-status":
            let isProcessing = (json["isProcessing"] as? Bool) ?? false
            return .sessionStatus(sessionId: sessionId, isProcessing: isProcessing)

        case "error":
            let msg = (json["error"] as? String)
                   ?? (json["message"] as? String)
                   ?? "Unknown error"
            let sid: String? = sessionId.isEmpty ? nil : sessionId
            return .error(sessionId: sid, message: msg)

        // ── IM hub `type` frames (subsystem 1) ───────────────────────────────

        case "im:message":
            if let msgObj = json["message"],
               let msgData = try? JSONSerialization.data(withJSONObject: msgObj),
               let dto = try? JSONDecoder().decode(ImMessageDTO.self, from: msgData) {
                let convId = (json["conversationId"] as? String) ?? dto.conversationId
                return .imMessage(conversationId: convId, message: dto)
            }
            return .raw(kind: kind, type: type_, payload: rawData)

        case "im:read":
            return .imRead(
                conversationId: (json["conversationId"] as? String) ?? "",
                deviceId: (json["deviceId"] as? String) ?? "",
                lastReadSeq: (json["lastReadSeq"] as? Int) ?? 0)

        case "im:poke":
            return .imPoke(since: (json["since"] as? Int) ?? 0)

        case "im:status":
            let convId = (json["conversationId"] as? String) ?? sessionId
            let isProcessing = (json["isProcessing"] as? Bool) ?? false
            let toolCount = (json["toolCount"] as? Int) ?? 0
            let currentTool = json["currentTool"] as? String
            return .imStatus(conversationId: convId, isProcessing: isProcessing,
                             toolCount: toolCount, currentTool: currentTool)

        default:
            return .raw(kind: kind, type: type_, payload: rawData)
        }
    }
}
