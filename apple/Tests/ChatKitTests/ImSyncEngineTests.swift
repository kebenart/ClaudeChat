import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class ImSyncEngineTests: XCTestCase {
    private func makeStorage() throws -> Storage {
        Storage(container: try StorageContainer.makeInMemory())
    }

    func testApplySyncPersistsAndSetsCursor() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        let resp = ImSyncResponse(
            messages: [ImMessageDTO(id: "s1", conversationId: "c1", seq: 1, role: "user", kind: "text", content: "hi", createdAt: 1)],
            conversations: [ImConversationDTO(id: "c1", contactId: nil, providerId: "claude", title: "C1",
                lastMessagePreview: "hi", lastSeq: 1, lastActivityAt: 1, isPinned: false, isMuted: false)],
            readCursors: [ImReadCursorDTO(conversationId: "c1", deviceId: "devA", lastReadSeq: 0)],
            cursor: 5, hasMore: false)
        await engine.applySync(resp)
        let cursor = await storage.imSyncCursor()
        XCTAssertEqual(cursor, 5)
        let count = await storage.imMessages(conversationId: "c1").count
        XCTAssertEqual(count, 1)
    }

    func testComputeUnreadUsesMaxReadAcrossDevices() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 5, lastActivityAt: 1, isPinned: false, isMuted: false))
        await storage.setImReadCursor(conversationId: "c1", deviceId: "phone", lastReadSeq: 5)
        await storage.setImReadCursor(conversationId: "c1", deviceId: "desktop", lastReadSeq: 2)
        let unread = await engine.computeUnread()
        XCTAssertEqual(unread["c1"] ?? 0, 0) // read on phone (max=5) clears everywhere; absent key == 0
    }

    func testApplyFrameImMessageBumpsConversation() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 1, lastActivityAt: 1, isPinned: false, isMuted: false))
        await engine.applyFrame(.imMessage(conversationId: "c1",
            message: ImMessageDTO(id: "a1", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "done", createdAt: 9)))
        let convs = await storage.imConversations()
        let conv = convs.first { $0.id == "c1" }
        XCTAssertEqual(conv?.lastSeq, 2)
        XCTAssertEqual(conv?.lastMessagePreview, "done")
        let unread = await engine.computeUnread()
        XCTAssertEqual(unread["c1"], 1) // one unread assistant reply (kind "result")
    }

    func testApplyFrameImMessageForUnknownConversationCreatesPlaceholder() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        // No conversation synced yet — a realtime frame should still surface it.
        await engine.applyFrame(.imMessage(conversationId: "new1",
            message: ImMessageDTO(id: "m1", conversationId: "new1", seq: 1, role: "assistant", kind: "result", content: "hello", createdAt: 5)))
        let convs = await storage.imConversations()
        let conv = convs.first { $0.id == "new1" }
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.lastSeq, 1)
        XCTAssertEqual(conv?.lastMessagePreview, "hello")
        let unread = await engine.computeUnread()
        XCTAssertEqual(unread["new1"], 1)
    }

    func testApplyFrameImReadClearsUnread() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 3, lastActivityAt: 1, isPinned: false, isMuted: false))
        // Three assistant replies (distill kind "result") → three unread before reading.
        await storage.upsertImMessages([
            ImMessageDTO(id: "a1", conversationId: "c1", seq: 1, role: "assistant", kind: "result", content: "1", createdAt: 1),
            ImMessageDTO(id: "a2", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "2", createdAt: 2),
            ImMessageDTO(id: "a3", conversationId: "c1", seq: 3, role: "assistant", kind: "result", content: "3", createdAt: 3),
        ])
        let before = await engine.computeUnread()
        XCTAssertEqual(before["c1"], 3)
        await engine.applyFrame(.imRead(conversationId: "c1", deviceId: "phone", lastReadSeq: 3))
        let after = await engine.computeUnread()
        XCTAssertEqual(after["c1"] ?? 0, 0) // fully read → absent key == 0
    }

    /// Regression: a conversation where I sent messages but Claude has not yet
    /// replied must show **zero** unread — my own outgoing messages (role
    /// "user") and tool-result/meta frames never count toward the badge.
    func testComputeUnreadIgnoresMyOwnAndNonReplyMessages() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 4, lastActivityAt: 1, isPinned: false, isMuted: false))
        await storage.upsertImMessages([
            ImMessageDTO(id: "u1", conversationId: "c1", seq: 1, role: "user", kind: "text", content: "hi", createdAt: 1),
            ImMessageDTO(id: "t1", conversationId: "c1", seq: 2, role: "assistant", kind: "tool_use", content: "", createdAt: 2),
            ImMessageDTO(id: "r1", conversationId: "c1", seq: 3, role: "user", kind: "tool_result", content: "", createdAt: 3),
            ImMessageDTO(id: "a1", conversationId: "c1", seq: 4, role: "assistant", kind: "result", content: "reply", createdAt: 4),
        ])
        let unread = await engine.computeUnread()
        XCTAssertEqual(unread["c1"], 1) // only the single assistant result reply counts
    }
}
