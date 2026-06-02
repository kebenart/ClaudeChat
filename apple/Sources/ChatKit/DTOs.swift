import Foundation

// ============================================================================
// Auth
// ============================================================================

public struct User: Codable, Hashable, Sendable {
    public let id: Int
    public let username: String
    public let totpEnabled: Bool?

    public init(id: Int, username: String, totpEnabled: Bool? = nil) {
        self.id = id
        self.username = username
        self.totpEnabled = totpEnabled
    }
}

public struct LoginResponse: Codable, Hashable, Sendable {
    public let token: String?
    public let user: User?
    public let requiresTotp: Bool?
    /// Short-lived JWT (5 min) issued by the backend when TOTP is required.
    /// Client must echo it back to `/api/auth/login/totp` along with the 6-digit code.
    public let totpToken: String?
    /// Rotated recovery code returned by `/api/auth/login/totp` when the user
    /// authenticated using a recovery code (server/routes/auth.js:232-237).
    /// Must be shown to the user — the previous recovery code is now invalid.
    public let newRecoveryCode: String?

    public init(token: String? = nil, user: User? = nil,
                requiresTotp: Bool? = nil, totpToken: String? = nil,
                newRecoveryCode: String? = nil) {
        self.token = token
        self.user = user
        self.requiresTotp = requiresTotp
        self.totpToken = totpToken
        self.newRecoveryCode = newRecoveryCode
    }
}

// ============================================================================
// Projects / Sessions
// ============================================================================

public struct ProjectInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String           // encoded directory name used by backend
    public let name: String?        // optional friendly name
    public let displayName: String  // backend-resolved display
    public let path: String         // workspace path
    public let fullPath: String?

    public init(id: String, name: String? = nil, displayName: String, path: String, fullPath: String? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.path = path
        self.fullPath = fullPath
    }
}

public struct SessionInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let projectPath: String
    public let projectDisplayName: String?
    public let title: String?
    public let lastActivityAt: Date?
    public let isActive: Bool?
    public let messageCount: Int?
    /// Client-only nickname/note. When set, shown instead of `title` in lists.
    public let note: String?
    /// Client-only pin flag. Pinned sessions sort to the top of the sidebar.
    public let isPinned: Bool
    /// Unread message count. Mirrored from `SessionRecord.unreadCount`.
    public let unreadCount: Int
    /// Denormalised last-message preview (~80 chars). Updated by storage on
    /// every message upsert / stream delta. nil for sessions with no messages.
    public let latestMessagePreview: String?
    /// Client-only mute flag — true means notifications / unread badge are
    /// suppressed for this session.
    public let isMuted: Bool

    public init(id: String, projectPath: String, projectDisplayName: String? = nil,
                title: String? = nil, lastActivityAt: Date? = nil,
                isActive: Bool? = nil, messageCount: Int? = nil,
                note: String? = nil, isPinned: Bool = false,
                unreadCount: Int = 0, latestMessagePreview: String? = nil,
                isMuted: Bool = false) {
        self.id = id
        self.projectPath = projectPath
        self.projectDisplayName = projectDisplayName
        self.title = title
        self.lastActivityAt = lastActivityAt
        self.isActive = isActive
        self.messageCount = messageCount
        self.note = note
        self.isPinned = isPinned
        self.unreadCount = unreadCount
        self.latestMessagePreview = latestMessagePreview
        self.isMuted = isMuted
    }

    /// Effective display name: note (nickname) if set, else title, else id-prefix.
    public var displayName: String {
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return String(id.prefix(8))
    }
}

// ============================================================================
// Messages
// ============================================================================

public enum MessageRole: String, Codable, Hashable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum ApprovalState: String, Codable, Hashable, CaseIterable, Sendable {
    case pending
    case approved
    case rejected
    case autoApproved
    case timedOut
    case cancelled
}

/// Delivery status of a user-sent message. WeChat-style: an icon next to the
/// bubble indicates send failures or in-flight sends.
public enum SendStatus: String, Codable, Hashable, CaseIterable, Sendable {
    /// Local insert; awaiting WS send confirmation.
    case sending
    /// WS send returned without throwing.
    case sent
    /// WS send threw, or no server reply within the timeout window.
    case failed
    /// Server emitted a `complete` event for this session — Claude responded.
    case delivered
}

public struct ToolInvocation: Codable, Hashable, Sendable {
    public let name: String              // "Read", "Edit", "Bash", "Grep", ...
    public var input: String             // JSON-string form of the tool's input
    public var output: String?
    public var approvalState: ApprovalState?
    public var requestId: String?
    public var requiresApproval: Bool

    public init(name: String, input: String, output: String? = nil,
                approvalState: ApprovalState? = nil, requestId: String? = nil,
                requiresApproval: Bool = false) {
        self.name = name
        self.input = input
        self.output = output
        self.approvalState = approvalState
        self.requestId = requestId
        self.requiresApproval = requiresApproval
    }
}

public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let role: MessageRole
    public var content: String
    public var toolUse: ToolInvocation?
    public let createdAt: Date
    public var isStreaming: Bool
    /// Delivery status for `role == .user` messages. nil for assistant/tool/system.
    public var sendStatus: SendStatus?
    /// Human-readable explanation when `sendStatus == .failed`. Shown in the
    /// popover that opens when the user clicks the red exclamation mark.
    public var sendError: String?

    public init(id: String, sessionId: String, role: MessageRole,
                content: String, toolUse: ToolInvocation? = nil,
                createdAt: Date = Date(), isStreaming: Bool = false,
                sendStatus: SendStatus? = nil, sendError: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.toolUse = toolUse
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.sendStatus = sendStatus
        self.sendError = sendError
    }
}

// ============================================================================
// Claude Code slash commands
// ============================================================================

public struct CommandInfo: Codable, Hashable, Identifiable, Sendable {
    public let name: String           // "/help"
    public let description: String
    public let namespace: String      // "builtin" / "user" / "project" / other
    public var id: String { namespace + name }

    public init(name: String, description: String, namespace: String) {
        self.name = name
        self.description = description
        self.namespace = namespace
    }
}

// ============================================================================
// Server profile (account = url + username)
// ============================================================================

public struct ServerProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var url: URL
    public var displayName: String
    public var username: String
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), url: URL, displayName: String,
                username: String, lastUsedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.username = username
        self.lastUsedAt = lastUsedAt
    }
}

// ============================================================================
// Search results
// ============================================================================

public struct SearchResults: Hashable, Sendable {
    public let matchingSessions: [SessionInfo]
    public let matchingMessages: [(sessionId: String, message: ChatMessage)]

    public init(matchingSessions: [SessionInfo] = [],
                matchingMessages: [(sessionId: String, message: ChatMessage)] = []) {
        self.matchingSessions = matchingSessions
        self.matchingMessages = matchingMessages
    }

    public static func == (lhs: SearchResults, rhs: SearchResults) -> Bool {
        lhs.matchingSessions == rhs.matchingSessions
            && lhs.matchingMessages.count == rhs.matchingMessages.count
            && zip(lhs.matchingMessages, rhs.matchingMessages).allSatisfy { $0.sessionId == $1.sessionId && $0.message == $1.message }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(matchingSessions)
        for (sid, msg) in matchingMessages {
            hasher.combine(sid)
            hasher.combine(msg)
        }
    }
}
