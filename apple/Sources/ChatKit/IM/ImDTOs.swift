import Foundation

/// Folded tool activity for the gray collapsed bar. `count` = number of tool
/// operations (tool_use blocks). rawRef* span the raw jsonl entry id range of
/// the turn's tool activity, for the "view full record" viewer.
public struct ImToolTrace: Codable, Hashable, Sendable {
    public let count: Int
    public let rawRefStart: String
    public let rawRefEnd: String

    public init(count: Int, rawRefStart: String, rawRefEnd: String) {
        self.count = count
        self.rawRefStart = rawRefStart
        self.rawRefEnd = rawRefEnd
    }
}

public struct ImMessageDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let conversationId: String
    public let seq: Int
    public let role: String
    public let kind: String
    public let content: String
    public let createdAt: Int   // epoch milliseconds
    public let toolTrace: ImToolTrace?
    /// Server P2 long-message truncation hint. When `true`, `content` holds only
    /// the first 800 chars and `fullLength` is the original length; the full body
    /// is fetched lazily via `APIClient.fetchMessageContent`. Absent → nil (short
    /// message). Display-only — not required to round-trip through storage; see
    /// `isTruncated`, which re-derives it when storage drops the hint.
    public let truncated: Bool?
    /// Original (pre-truncation) length of `content`. Present iff `truncated`.
    public let fullLength: Int?

    public init(id: String, conversationId: String, seq: Int, role: String, kind: String,
                content: String, createdAt: Int, toolTrace: ImToolTrace? = nil,
                truncated: Bool? = nil, fullLength: Int? = nil) {
        self.id = id; self.conversationId = conversationId; self.seq = seq
        self.role = role; self.kind = kind; self.content = content
        self.createdAt = createdAt; self.toolTrace = toolTrace
        self.truncated = truncated; self.fullLength = fullLength
    }

    /// Whether this message's `content` is a server-side truncated preview. Reads
    /// the explicit hint when present (live frame / sync), and otherwise re-derives
    /// it from the stored shape (`content.count >= 800 && fullLength != nil`) so it
    /// still works after a SwiftData round-trip that didn't carry the flag. Falls
    /// back to a pure length check (>= 800) as a last resort.
    public var isTruncated: Bool {
        if let truncated { return truncated }
        if let fullLength { return content.count >= 800 && fullLength > content.count }
        return false
    }
}

public struct ImConversationDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let contactId: String?
    public let providerId: String
    public let title: String?
    public let lastMessagePreview: String?
    public let lastSeq: Int
    public let lastActivityAt: Int
    public let isPinned: Bool
    public let isMuted: Bool
    /// Server-synced custom nickname (备注名), nil if none.
    public let note: String?
    /// Server-synced WeChat "折叠的聊天" flag.
    public let isFolded: Bool
    /// Server-synced "已删除" flag (WeChat-style delete-chat). Hidden on every
    /// client; resurrected server-side when a new message arrives.
    public let isDeleted: Bool

    public init(id: String, contactId: String?, providerId: String, title: String?,
                lastMessagePreview: String?, lastSeq: Int, lastActivityAt: Int,
                isPinned: Bool, isMuted: Bool, note: String? = nil, isFolded: Bool = false,
                isDeleted: Bool = false) {
        self.id = id; self.contactId = contactId; self.providerId = providerId
        self.title = title; self.lastMessagePreview = lastMessagePreview
        self.lastSeq = lastSeq; self.lastActivityAt = lastActivityAt
        self.isPinned = isPinned; self.isMuted = isMuted
        self.note = note; self.isFolded = isFolded; self.isDeleted = isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contactId = try c.decodeIfPresent(String.self, forKey: .contactId)
        providerId = try c.decode(String.self, forKey: .providerId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastSeq = try c.decode(Int.self, forKey: .lastSeq)
        lastActivityAt = try c.decode(Int.self, forKey: .lastActivityAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isFolded = try c.decodeIfPresent(Bool.self, forKey: .isFolded) ?? false
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }

    /// Copy with field overrides (omitted args keep the current value). `note`
    /// is double-optional so `.some(nil)` clears it and the default keeps it.
    public func with(isPinned: Bool? = nil, isMuted: Bool? = nil,
                     isFolded: Bool? = nil, isDeleted: Bool? = nil,
                     note: String?? = nil) -> ImConversationDTO {
        ImConversationDTO(
            id: id, contactId: contactId, providerId: providerId, title: title,
            lastMessagePreview: lastMessagePreview, lastSeq: lastSeq, lastActivityAt: lastActivityAt,
            isPinned: isPinned ?? self.isPinned, isMuted: isMuted ?? self.isMuted,
            note: note ?? self.note, isFolded: isFolded ?? self.isFolded,
            isDeleted: isDeleted ?? self.isDeleted)
    }
}

public struct ImReadCursorDTO: Codable, Hashable, Sendable {
    public let conversationId: String
    public let deviceId: String
    public let lastReadSeq: Int

    public init(conversationId: String, deviceId: String, lastReadSeq: Int) {
        self.conversationId = conversationId; self.deviceId = deviceId; self.lastReadSeq = lastReadSeq
    }
}

public struct ImSyncResponse: Codable, Sendable {
    public let messages: [ImMessageDTO]
    public let conversations: [ImConversationDTO]
    public let readCursors: [ImReadCursorDTO]
    public let cursor: Int
    public let hasMore: Bool
}

/// One entry in the raw, un-distilled transcript ("view full record"). Big
/// content is summarized; full payload is fetched separately by id.
public struct ImTranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let type: String
    /// jsonl role ('user' | 'assistant' | …) — optional for back-compat.
    public let role: String?
    /// Coarse classification (text/tool_use/tool_result/thinking/meta); non-'text'
    /// kinds are folded in the viewer. Optional for back-compat.
    public let kind: String?
    public let summary: String
    public let hasBlob: Bool
}

public struct ImTranscriptPage: Codable, Sendable {
    public let entries: [ImTranscriptEntry]
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool
}
