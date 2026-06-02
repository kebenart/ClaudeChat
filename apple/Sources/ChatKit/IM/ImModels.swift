import Foundation
import SwiftData

@Model public final class ImConversationRecord {
    @Attribute(.unique) public var id: String
    public var contactId: String?
    public var providerId: String
    public var title: String?
    public var lastMessagePreview: String?
    public var lastSeq: Int
    public var lastActivityAt: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var note: String?
    public var isFolded: Bool = false
    public var isDeleted: Bool = false

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
}

@Model public final class ImMessageRecord {
    @Attribute(.unique) public var id: String
    public var conversationId: String
    public var seq: Int
    public var role: String
    public var kind: String
    public var content: String
    public var createdAt: Int
    public var toolTraceCount: Int
    public var rawRefStart: String?
    public var rawRefEnd: String?
    /// Server P2 long-message truncation hints. Default values keep the SwiftData
    /// store backward-compatible (lightweight migration) for pre-P2 caches.
    public var truncated: Bool = false
    public var fullLength: Int = 0

    public init(id: String, conversationId: String, seq: Int, role: String, kind: String,
                content: String, createdAt: Int, toolTraceCount: Int,
                rawRefStart: String?, rawRefEnd: String?,
                truncated: Bool = false, fullLength: Int = 0) {
        self.id = id; self.conversationId = conversationId; self.seq = seq
        self.role = role; self.kind = kind; self.content = content; self.createdAt = createdAt
        self.toolTraceCount = toolTraceCount; self.rawRefStart = rawRefStart; self.rawRefEnd = rawRefEnd
        self.truncated = truncated; self.fullLength = fullLength
    }
}

@Model public final class ImReadCursorRecord {
    /// Composite key flattened: "<conversationId>\t<deviceId>".
    @Attribute(.unique) public var id: String
    public var conversationId: String
    public var deviceId: String
    public var lastReadSeq: Int

    public init(conversationId: String, deviceId: String, lastReadSeq: Int) {
        self.id = "\(conversationId)\t\(deviceId)"
        self.conversationId = conversationId; self.deviceId = deviceId; self.lastReadSeq = lastReadSeq
    }
}

@Model public final class ImSyncStateRecord {
    @Attribute(.unique) public var id: String  // always "cursor"
    public var cursor: Int
    public init(cursor: Int) { self.id = "cursor"; self.cursor = cursor }
}
