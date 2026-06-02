import Foundation
import SwiftData

// IM extensions on the existing Storage actor. Mirror the wire model; the
// distilled IM data is separate from the provider SessionRecord/MessageRecord.
// These methods are actor-isolated (callers use `await`).
extension Storage {
    public func upsertImConversation(_ c: ImConversationDTO) {
        let id = c.id
        let existing = try? context.fetch(FetchDescriptor<ImConversationRecord>(
            predicate: #Predicate { $0.id == id })).first
        if let r = existing {
            r.contactId = c.contactId; r.providerId = c.providerId; r.title = c.title
            r.lastMessagePreview = c.lastMessagePreview; r.lastSeq = c.lastSeq
            r.lastActivityAt = c.lastActivityAt; r.isPinned = c.isPinned; r.isMuted = c.isMuted
            r.note = c.note; r.isFolded = c.isFolded; r.isDeleted = c.isDeleted
        } else {
            context.insert(ImConversationRecord(
                id: c.id, contactId: c.contactId, providerId: c.providerId, title: c.title,
                lastMessagePreview: c.lastMessagePreview, lastSeq: c.lastSeq,
                lastActivityAt: c.lastActivityAt, isPinned: c.isPinned, isMuted: c.isMuted,
                note: c.note, isFolded: c.isFolded, isDeleted: c.isDeleted))
        }
        try? context.save()
    }

    public func upsertImMessages(_ messages: [ImMessageDTO]) {
        for m in messages {
            let id = m.id
            let existing = try? context.fetch(FetchDescriptor<ImMessageRecord>(
                predicate: #Predicate { $0.id == id })).first
            if let r = existing {
                r.seq = m.seq; r.role = m.role; r.kind = m.kind; r.content = m.content
                r.createdAt = m.createdAt; r.toolTraceCount = m.toolTrace?.count ?? 0
                r.rawRefStart = m.toolTrace?.rawRefStart; r.rawRefEnd = m.toolTrace?.rawRefEnd
                r.truncated = m.truncated ?? false; r.fullLength = m.fullLength ?? 0
            } else {
                context.insert(ImMessageRecord(
                    id: m.id, conversationId: m.conversationId, seq: m.seq, role: m.role,
                    kind: m.kind, content: m.content, createdAt: m.createdAt,
                    toolTraceCount: m.toolTrace?.count ?? 0,
                    rawRefStart: m.toolTrace?.rawRefStart, rawRefEnd: m.toolTrace?.rawRefEnd,
                    truncated: m.truncated ?? false, fullLength: m.fullLength ?? 0))
            }
        }
        try? context.save()
    }

    public func imConversations() -> [ImConversationDTO] {
        let rows = (try? context.fetch(FetchDescriptor<ImConversationRecord>())) ?? []
        return rows.map { r in
            ImConversationDTO(id: r.id, contactId: r.contactId, providerId: r.providerId,
                              title: r.title, lastMessagePreview: r.lastMessagePreview,
                              lastSeq: r.lastSeq, lastActivityAt: r.lastActivityAt,
                              isPinned: r.isPinned, isMuted: r.isMuted,
                              note: r.note, isFolded: r.isFolded, isDeleted: r.isDeleted)
        }
    }

    /// Single-row fetch by id (uses the `.unique` id index). The hot live-frame
    /// path (ImSyncEngine.applyFrame) uses this instead of materializing the
    /// ENTIRE conversation table just to find one row by id on every frame.
    public func imConversation(id: String) -> ImConversationDTO? {
        let cid = id
        guard let r = try? context.fetch(FetchDescriptor<ImConversationRecord>(
            predicate: #Predicate { $0.id == cid })).first else { return nil }
        return ImConversationDTO(id: r.id, contactId: r.contactId, providerId: r.providerId,
                                 title: r.title, lastMessagePreview: r.lastMessagePreview,
                                 lastSeq: r.lastSeq, lastActivityAt: r.lastActivityAt,
                                 isPinned: r.isPinned, isMuted: r.isMuted,
                                 note: r.note, isFolded: r.isFolded, isDeleted: r.isDeleted)
    }

    /// Lightweight (conversationId, seq) pairs for every assistant *reply*
    /// message (kind result/error/text), fetched in ONE query. Used by
    /// `computeUnread` so it no longer runs a separate full-message fetch per
    /// conversation (157 queries → 1), which was a major CPU/heat source when a
    /// few conversations hold 1000+ messages.
    public func imReplyMessageSeqs() -> [(conversationId: String, seq: Int)] {
        let rows = (try? context.fetch(FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate {
                $0.role == "assistant"
                    && ($0.kind == "result" || $0.kind == "error" || $0.kind == "text")
            }))) ?? []
        return rows.map { ($0.conversationId, $0.seq) }
    }

    private func dto(_ r: ImMessageRecord) -> ImMessageDTO {
        let trace: ImToolTrace? = (r.toolTraceCount > 0 && r.rawRefStart != nil && r.rawRefEnd != nil)
            ? ImToolTrace(count: r.toolTraceCount, rawRefStart: r.rawRefStart!, rawRefEnd: r.rawRefEnd!)
            : nil
        return ImMessageDTO(id: r.id, conversationId: r.conversationId, seq: r.seq, role: r.role,
                            kind: r.kind, content: r.content, createdAt: r.createdAt, toolTrace: trace,
                            truncated: r.truncated ? true : nil,
                            fullLength: r.fullLength > 0 ? r.fullLength : nil)
    }

    public func imMessages(conversationId: String) -> [ImMessageDTO] {
        let cid = conversationId
        let rows = (try? context.fetch(FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate { $0.conversationId == cid },
            sortBy: [SortDescriptor(\.seq, order: .forward)]))) ?? []
        return rows.map(dto)
    }

    /// The single newest message (highest seq) for a conversation, or nil. A
    /// `fetchLimit = 1` query — used by the "is the latest message an assistant
    /// reply?" check so it doesn't load an ENTIRE conversation just to read the
    /// last row (that full fetch, run on every refresh, was a real stall).
    public func lastImMessage(conversationId: String) -> ImMessageDTO? {
        let cid = conversationId
        var desc = FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate { $0.conversationId == cid },
            sortBy: [SortDescriptor(\.seq, order: .reverse)])
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first.map(dto)
    }

    /// The most-recent `limit` messages (ascending). Lets the chat view window to
    /// the tail instead of loading an entire long conversation into memory on
    /// every reload — older pages are revealed by growing the window and
    /// back-filled from the server only when the local tail is exhausted.
    public func imMessages(conversationId: String, limit: Int) -> [ImMessageDTO] {
        let cid = conversationId
        var desc = FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate { $0.conversationId == cid },
            sortBy: [SortDescriptor(\.seq, order: .reverse)])
        desc.fetchLimit = max(0, limit)
        let rows = (try? context.fetch(desc)) ?? []
        return rows.reversed().map(dto)
    }

    public func imMessageCount(conversationId: String) -> Int {
        let cid = conversationId
        return (try? context.fetchCount(FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate { $0.conversationId == cid }))) ?? 0
    }

    public func setImReadCursor(conversationId: String, deviceId: String, lastReadSeq: Int) {
        let key = "\(conversationId)\t\(deviceId)"
        let existing = try? context.fetch(FetchDescriptor<ImReadCursorRecord>(
            predicate: #Predicate { $0.id == key })).first
        if let r = existing {
            r.lastReadSeq = max(r.lastReadSeq, lastReadSeq)
        } else {
            context.insert(ImReadCursorRecord(conversationId: conversationId, deviceId: deviceId, lastReadSeq: lastReadSeq))
        }
        try? context.save()
    }

    public func imReadCursors() -> [ImReadCursorDTO] {
        let rows = (try? context.fetch(FetchDescriptor<ImReadCursorRecord>())) ?? []
        return rows.map { ImReadCursorDTO(conversationId: $0.conversationId, deviceId: $0.deviceId, lastReadSeq: $0.lastReadSeq) }
    }

    public func imSyncCursor() -> Int {
        ((try? context.fetch(FetchDescriptor<ImSyncStateRecord>()))?.first?.cursor) ?? 0
    }

    public func setImSyncCursor(_ cursor: Int) {
        if let r = try? context.fetch(FetchDescriptor<ImSyncStateRecord>()).first {
            r.cursor = cursor
        } else {
            context.insert(ImSyncStateRecord(cursor: cursor))
        }
        try? context.save()
    }
}
