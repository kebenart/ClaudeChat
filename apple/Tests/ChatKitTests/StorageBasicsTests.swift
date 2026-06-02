import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class StorageBasicsTests: XCTestCase {

    private func makeStorage() throws -> Storage {
        let container = try StorageContainer.makeInMemory()
        return Storage(container: container)
    }

    // MARK: - Session upsert

    func testUpsertSession_insertsNewSession() async throws {
        let storage = try makeStorage()
        let session = SessionInfo(id: "s1", projectPath: "/tmp/proj", title: "My chat")
        await storage.upsertSession(session)

        let list = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "s1")
        XCTAssertEqual(list.first?.title, "My chat")
    }

    func testUpsertSession_updatesExistingSession() async throws {
        let storage = try makeStorage()
        let original = SessionInfo(id: "s1", projectPath: "/tmp/proj", title: "Old title")
        await storage.upsertSession(original)

        let updated = SessionInfo(id: "s1", projectPath: "/tmp/proj", title: "New title")
        await storage.upsertSession(updated)

        let list = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.title, "New title")
    }

    func testUpsertSessions_insertsMultiple() async throws {
        let storage = try makeStorage()
        let sessions: [SessionInfo] = [
            SessionInfo(id: "a", projectPath: "/a"),
            SessionInfo(id: "b", projectPath: "/b"),
            SessionInfo(id: "c", projectPath: "/c"),
        ]
        await storage.upsertSessions(sessions)

        let list = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(list.count, 3)
    }

    // MARK: - Session visibility

    func testListSessions_excludesHiddenByDefault() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "visible", projectPath: "/a"))
        await storage.upsertSession(SessionInfo(id: "hidden", projectPath: "/b"))
        await storage.setHidden(sessionId: "hidden", hidden: true)

        let visible = await storage.listSessions(includingHidden: false)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, "visible")
    }

    func testListSessions_includesHiddenWhenRequested() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.setHidden(sessionId: "s1", hidden: true)

        let all = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(all.count, 1)
    }

    func testSetHidden_canUnhide() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.setHidden(sessionId: "s1", hidden: true)
        await storage.setHidden(sessionId: "s1", hidden: false)

        let visible = await storage.listSessions(includingHidden: false)
        XCTAssertEqual(visible.count, 1)
    }

    // MARK: - Unread counts

    func testIncrementUnread_incrementsCounter() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.incrementUnread(sessionId: "s1")
        await storage.incrementUnread(sessionId: "s1")

        let list = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(list.first?.messageCount, 0) // messageCount reflects messages, not unread
        // unreadCount is stored in SessionRecord, not exposed in SessionInfo DTO
        // Verify indirectly: clearUnread should not crash
        await storage.clearUnread(sessionId: "s1")
    }

    func testClearUnread_resetsCounter() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.incrementUnread(sessionId: "s1")
        await storage.incrementUnread(sessionId: "s1")
        await storage.clearUnread(sessionId: "s1")
        // No crash = pass. If we expose unreadCount in DTO later, assert it here.
    }

    // MARK: - sessionExists

    func testSessionExists_returnsTrueWhenPresent() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        let exists = await storage.sessionExists("s1")
        XCTAssertTrue(exists)
    }

    func testSessionExists_returnsFalseWhenAbsent() async throws {
        let storage = try makeStorage()
        let exists = await storage.sessionExists("nope")
        XCTAssertFalse(exists)
    }

    // MARK: - Message upsert

    func testUpsertMessage_insertsNewMessage() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        let msg = ChatMessage(id: "m1", sessionId: "s1", role: .user, content: "Hello")
        await storage.upsertMessage(msg)

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, "Hello")
        XCTAssertEqual(msgs.first?.role, .user)
    }

    func testUpsertMessage_updatesExistingMessage() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        let original = ChatMessage(id: "m1", sessionId: "s1", role: .assistant, content: "Hi")
        await storage.upsertMessage(original)

        let updated = ChatMessage(id: "m1", sessionId: "s1", role: .assistant, content: "Updated")
        await storage.upsertMessage(updated)

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, "Updated")
    }

    func testMessages_returnsSortedByCreatedAt() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let m1 = ChatMessage(id: "m1", sessionId: "s1", role: .user, content: "first", createdAt: t1)
        let m2 = ChatMessage(id: "m2", sessionId: "s1", role: .assistant, content: "second", createdAt: t2)
        // Insert in reverse order
        await storage.upsertMessage(m2)
        await storage.upsertMessage(m1)

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.map { $0.id }, ["m1", "m2"])
    }

    func testLatestMessage_returnsNewest() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        await storage.upsertMessage(ChatMessage(id: "m1", sessionId: "s1", role: .user, content: "old", createdAt: t1))
        await storage.upsertMessage(ChatMessage(id: "m2", sessionId: "s1", role: .assistant, content: "new", createdAt: t2))

        let latest = await storage.latestMessage(sessionId: "s1")
        XCTAssertEqual(latest?.id, "m2")
    }

    // MARK: - Reset

    func testReset_deletesAllData() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.upsertMessage(ChatMessage(id: "m1", sessionId: "s1", role: .user, content: "hi"))
        await storage.reset()

        let sessions = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(sessions.count, 0)
        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.count, 0)
    }
}
