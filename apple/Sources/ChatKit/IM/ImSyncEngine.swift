import Foundation

/// Local-first IM sync engine. Folds /sync responses and im:* frames into the
/// Storage actor, and computes per-conversation unread.
public actor ImSyncEngine {
    private let storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }

    /// Apply a full or incremental /sync response.
    public func applySync(_ resp: ImSyncResponse) async {
        for c in resp.conversations { await storage.upsertImConversation(c) }
        if !resp.messages.isEmpty {
            await storage.upsertImMessages(resp.messages)
        }
        for rc in resp.readCursors {
            await storage.setImReadCursor(conversationId: rc.conversationId, deviceId: rc.deviceId, lastReadSeq: rc.lastReadSeq)
        }
        await storage.setImSyncCursor(resp.cursor)
    }

    /// Apply one incoming im:* server event. Returns true if it carried data
    /// (im:poke returns false — the caller decides whether to re-sync).
    @discardableResult
    public func applyFrame(_ event: ServerEvent) async -> Bool {
        switch event {
        case let .imMessage(conversationId, message):
            await storage.upsertImMessages([message])
            if let conv = await storage.imConversation(id: conversationId) {
                // Keep the existing conversation's lastSeq/preview in step.
                if message.seq >= conv.lastSeq {
                    await storage.upsertImConversation(ImConversationDTO(
                        id: conv.id, contactId: conv.contactId, providerId: conv.providerId, title: conv.title,
                        lastMessagePreview: String(message.content.prefix(120)),
                        lastSeq: message.seq, lastActivityAt: message.createdAt,
                        isPinned: conv.isPinned, isMuted: conv.isMuted,
                        note: conv.note, isFolded: conv.isFolded))
                }
            } else {
                // Realtime frame for a not-yet-synced conversation: create a
                // minimal placeholder so it surfaces immediately (a later /sync
                // fills in contactId/title). Without this the message would be
                // stored but invisible until the next full sync.
                await storage.upsertImConversation(ImConversationDTO(
                    id: conversationId, contactId: nil, providerId: "claude", title: nil,
                    lastMessagePreview: String(message.content.prefix(120)),
                    lastSeq: message.seq, lastActivityAt: message.createdAt,
                    isPinned: false, isMuted: false))
            }
            return true
        case let .imRead(conversationId, deviceId, lastReadSeq):
            await storage.setImReadCursor(conversationId: conversationId, deviceId: deviceId, lastReadSeq: lastReadSeq)
            return true
        default:
            return false
        }
    }

    /// Per-conversation unread = number of *Claude reply* messages whose seq is
    /// above the max read cursor across devices. We count actual reply rows
    /// rather than `lastSeq - maxRead`, because the latter also counts the user's
    /// own outgoing messages (and tool/meta frames), which made the badge inflate
    /// every time *I* sent something.
    /// Single-user: reading on any device (the max cursor) clears the dot everywhere.
    public func computeUnread() async -> [String: Int] {
        let cursors = await storage.imReadCursors()
        var maxRead: [String: Int] = [:]
        for c in cursors {
            maxRead[c.conversationId] = max(maxRead[c.conversationId] ?? 0, c.lastReadSeq)
        }
        // ONE fetch of all assistant reply seqs, then bucket in memory — avoids a
        // per-conversation message fetch (157 queries × full message scan) on
        // every refresh, which pegged the CPU when large conversations existed.
        let replySeqs = await storage.imReplyMessageSeqs()
        var counts: [String: Int] = [:]
        for r in replySeqs where r.seq > (maxRead[r.conversationId] ?? 0) {
            counts[r.conversationId, default: 0] += 1
        }
        // Returns ONLY conversations with ≥1 unread. Every caller reads
        // `counts[id] ?? 0`, so the dropped zero-entries (and the full
        // imConversations() fetch they used to require) cost nothing — this
        // removes one full conversation-table scan on every refresh.
        return counts
    }
}
