import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class StorageSearchTests: XCTestCase {

    private func makeStorage() throws -> Storage {
        let container = try StorageContainer.makeInMemory()
        return Storage(container: container)
    }

    private func populate(_ storage: Storage) async {
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a", title: "SwiftUI tips"))
        await storage.upsertSession(SessionInfo(id: "s2", projectPath: "/b", title: "Python scripts"))
        await storage.upsertSession(SessionInfo(id: "s3", projectPath: "/c", title: "Refactoring talk"))

        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let t3 = Date(timeIntervalSince1970: 300)

        await storage.upsertMessage(ChatMessage(id: "m1", sessionId: "s1", role: .user,
                                                content: "How do I use @State in SwiftUI?", createdAt: t1))
        await storage.upsertMessage(ChatMessage(id: "m2", sessionId: "s1", role: .assistant,
                                                content: "Use @State for local view state.", createdAt: t2))
        await storage.upsertMessage(ChatMessage(id: "m3", sessionId: "s2", role: .user,
                                                content: "Write a Python function for sorting.", createdAt: t3))
        await storage.upsertMessage(ChatMessage(id: "m4", sessionId: "s3", role: .assistant,
                                                content: "Let me help refactor that Swift code.", createdAt: t3))
    }

    // MARK: - Session title search

    func testSearch_matchesSessionTitle() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let results = await storage.search("swift")
        // "SwiftUI tips" and "Refactoring talk" do not contain "swift" in title,
        // but "SwiftUI" does (case-insensitive).
        let ids = results.matchingSessions.map { $0.id }
        XCTAssertTrue(ids.contains("s1"), "Expected 'SwiftUI tips' to match 'swift'")
    }

    func testSearch_matchesSessionTitleCaseInsensitive() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let lower = await storage.search("python")
        let upper = await storage.search("PYTHON")
        XCTAssertEqual(lower.matchingSessions.map { $0.id }.sorted(),
                       upper.matchingSessions.map { $0.id }.sorted())
    }

    func testSearch_noMatchReturnEmptySession() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let results = await storage.search("Kubernetes")
        XCTAssertTrue(results.matchingSessions.isEmpty)
    }

    // MARK: - Message content search

    func testSearch_matchesMessageContent() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let results = await storage.search("@State")
        let messageIds = results.matchingMessages.map { $0.message.id }
        XCTAssertTrue(messageIds.contains("m1"), "Expected m1 to match '@State'")
        XCTAssertTrue(messageIds.contains("m2"), "Expected m2 to match '@State'")
    }

    func testSearch_messageContentCaseInsensitive() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let r1 = await storage.search("sorting")
        let r2 = await storage.search("SORTING")
        XCTAssertEqual(r1.matchingMessages.map { $0.message.id }.sorted(),
                       r2.matchingMessages.map { $0.message.id }.sorted())
    }

    func testSearch_returnsCorrectSessionIdWithMessage() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let results = await storage.search("Python")
        let match = results.matchingMessages.first { $0.message.id == "m3" }
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.sessionId, "s2")
    }

    // MARK: - Empty query

    func testSearch_emptyQueryReturnsEmpty() async throws {
        let storage = try makeStorage()
        await populate(storage)

        let results = await storage.search("")
        XCTAssertTrue(results.matchingSessions.isEmpty)
        XCTAssertTrue(results.matchingMessages.isEmpty)
    }

    // MARK: - Cross-session isolation

    func testSearch_doesNotConfuseSessionsAndMessages() async throws {
        let storage = try makeStorage()
        await populate(storage)

        // "refactor" appears in both title (s3) and a message body (m4).
        let results = await storage.search("refactor")
        XCTAssertTrue(results.matchingSessions.map { $0.id }.contains("s3"))
        XCTAssertTrue(results.matchingMessages.map { $0.message.id }.contains("m4"))
    }
}
