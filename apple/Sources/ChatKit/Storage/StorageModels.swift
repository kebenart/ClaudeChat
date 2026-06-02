import Foundation
import SwiftData

// ============================================================================
// SwiftData @Model classes for the persistence layer.
//
// Key design notes:
// - All @Model instances live on the actor that owns the ModelContext.
//   Public surfaces must convert to DTOs (Sendable value types) before
//   crossing actor boundaries.
// - MessageRecord.id uniqueness: the backend's normalized messages do not
//   always include a stable id. When id is absent, callers must derive one
//   as "\(sessionId)-\(timestamp.timeIntervalSince1970)-\(role.rawValue)".
//   This scheme is documented at every creation site in Storage.swift.
// ============================================================================

@Model
final class SessionRecord {
    /// Unique, matches the backend's session UUID string.
    @Attribute(.unique) var id: String

    var projectPath: String
    var projectDisplayName: String?
    var title: String?

    /// Used as the avatar seed (colour + initials generation). Defaults to `id`.
    var avatarSeed: String

    /// Updated aggressively on any session activity so the sidebar sort is live.
    var lastActivityAt: Date

    var isHidden: Bool
    var unreadCount: Int
    var hasPendingApproval: Bool

    /// Client-only nickname. When set, shown instead of `title` in lists.
    var note: String?
    /// Client-only pin flag. Pinned sessions sort to the top of the sidebar.
    var isPinned: Bool
    /// Client-only mute flag. Muted sessions still show in the sidebar but the
    /// unread badge is dimmed, the row shows a speaker-slash icon and system
    /// notifications are suppressed.
    var isMuted: Bool = false
    /// Denormalised: snapshot of the last message's content (≤ 80 chars).
    /// Maintained by `Storage.upsertMessage` / `appendStreamDelta`.
    var latestMessagePreview: String?

    @Relationship(deleteRule: .cascade)
    var messages: [MessageRecord]

    init(
        id: String,
        projectPath: String,
        projectDisplayName: String? = nil,
        title: String? = nil,
        lastActivityAt: Date = Date(),
        isHidden: Bool = false,
        unreadCount: Int = 0,
        hasPendingApproval: Bool = false,
        note: String? = nil,
        isPinned: Bool = false,
        isMuted: Bool = false
    ) {
        self.id = id
        self.projectPath = projectPath
        self.projectDisplayName = projectDisplayName
        self.title = title
        self.avatarSeed = id          // seed == id keeps colours stable per session
        self.lastActivityAt = lastActivityAt
        self.isHidden = isHidden
        self.unreadCount = unreadCount
        self.hasPendingApproval = hasPendingApproval
        self.note = note
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.latestMessagePreview = nil
        self.messages = []
    }

    /// Convert to the Sendable DTO that the rest of the system sees.
    func toDTO() -> SessionInfo {
        SessionInfo(
            id: id,
            projectPath: projectPath,
            projectDisplayName: projectDisplayName,
            title: title,
            lastActivityAt: lastActivityAt,
            isActive: hasPendingApproval ? true : nil,
            messageCount: messages.count,
            note: note,
            isPinned: isPinned,
            unreadCount: unreadCount,
            latestMessagePreview: latestMessagePreview,
            isMuted: isMuted
        )
    }
}

@Model
final class MessageRecord {
    /// Unique across all sessions. See derivation rule at the top of this file.
    @Attribute(.unique) var id: String

    var sessionId: String

    /// Raw value of `MessageRole` so SwiftData stores it without a custom transformer.
    var roleRaw: String

    var content: String

    // Tool-use fields — nil for non-tool messages.
    var toolName: String?
    var toolInput: String?
    var toolOutput: String?
    var toolApprovalStateRaw: String?   // raw value of ApprovalState
    var toolRequestId: String?

    var createdAt: Date
    var isStreaming: Bool
    /// SendStatus raw value, only meaningful for `role == .user`.
    var sendStatusRaw: String?
    /// Human-readable reason for a `.failed` send.
    var sendError: String?

    init(
        id: String,
        sessionId: String,
        role: MessageRole,
        content: String = "",
        toolName: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        toolApprovalState: ApprovalState? = nil,
        toolRequestId: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        sendStatus: SendStatus? = nil,
        sendError: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.roleRaw = role.rawValue
        self.content = content
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.toolApprovalStateRaw = toolApprovalState?.rawValue
        self.toolRequestId = toolRequestId
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.sendStatusRaw = sendStatus?.rawValue
        self.sendError = sendError
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .system }
        set { roleRaw = newValue.rawValue }
    }

    var toolApprovalState: ApprovalState? {
        get { toolApprovalStateRaw.flatMap { ApprovalState(rawValue: $0) } }
        set { toolApprovalStateRaw = newValue?.rawValue }
    }

    var sendStatus: SendStatus? {
        get { sendStatusRaw.flatMap { SendStatus(rawValue: $0) } }
        set { sendStatusRaw = newValue?.rawValue }
    }

    /// Convert to the Sendable DTO.
    func toDTO() -> ChatMessage {
        let toolUse: ToolInvocation? = toolName.map { name in
            ToolInvocation(
                name: name,
                input: toolInput ?? "",
                output: toolOutput,
                approvalState: toolApprovalState,
                requestId: toolRequestId,
                requiresApproval: toolApprovalState == .pending
            )
        }
        return ChatMessage(
            id: id,
            sessionId: sessionId,
            role: role,
            content: content,
            toolUse: toolUse,
            createdAt: createdAt,
            isStreaming: isStreaming,
            sendStatus: sendStatus,
            sendError: sendError
        )
    }
}
