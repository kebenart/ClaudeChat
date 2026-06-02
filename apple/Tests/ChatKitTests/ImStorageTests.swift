import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class ImStorageTests: XCTestCase {
    private func makeStorage() throws -> Storage {
        Storage(container: try StorageContainer.makeInMemory())
    }

    func testUpsertMessagesIsIdempotentAndOrdersBySeq() async throws {
        let storage = try makeStorage()
        await storage.upsertImConversation(ImConversationDTO(
            id: "c1", contactId: "/r", providerId: "claude", title: "C1",
            lastMessagePreview: "yo", lastSeq: 2, lastActivityAt: 20, isPinned: false, isMuted: false))
        await storage.upsertImMessages([
            ImMessageDTO(id: "s1", conversationId: "c1", seq: 1, role: "user", kind: "text", content: "hi", createdAt: 10),
            ImMessageDTO(id: "s2", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "yo", createdAt: 20),
        ])
        await storage.upsertImMessages([
            ImMessageDTO(id: "s2", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "yo more", createdAt: 21),
        ])

        let msgs = await storage.imMessages(conversationId: "c1")
        XCTAssertEqual(msgs.map(\.seq), [1, 2])
        XCTAssertEqual(msgs[1].content, "yo more")
        let convCount = await storage.imConversations().count
        XCTAssertEqual(convCount, 1)
    }

    func testReadCursorUsesMaxAndSyncCursorRoundTrips() async throws {
        let storage = try makeStorage()
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devA", lastReadSeq: 3)
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devA", lastReadSeq: 1)
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devB", lastReadSeq: 5)
        let cursors = await storage.imReadCursors()
        XCTAssertEqual(cursors.first(where: { $0.deviceId == "devA" })?.lastReadSeq, 3)
        XCTAssertEqual(cursors.count, 2)

        let c0 = await storage.imSyncCursor()
        XCTAssertEqual(c0, 0)
        await storage.setImSyncCursor(42)
        let c42 = await storage.imSyncCursor()
        XCTAssertEqual(c42, 42)
    }
}
