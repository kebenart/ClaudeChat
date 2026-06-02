import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class StorageStreamingTests: XCTestCase {

    private func makeStorage() throws -> Storage {
        let container = try StorageContainer.makeInMemory()
        return Storage(container: container)
    }

    // MARK: - appendStreamDelta

    func testAppendStreamDelta_createsMessageOnFirstDelta() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "Hello")

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.id, "m1")
        XCTAssertEqual(msgs.first?.content, "Hello")
        XCTAssertEqual(msgs.first?.role, .assistant)
        XCTAssertTrue(msgs.first?.isStreaming ?? false)
    }

    func testAppendStreamDelta_accumulatesContent() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "Hello")
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: ", ")
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "world!")

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.first?.content, "Hello, world!")
        XCTAssertTrue(msgs.first?.isStreaming ?? false)
    }

    func testAppendStreamDelta_keepsIsStreamingTrue() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "...")
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "still going")

        let msg = await storage.latestMessage(sessionId: "s1")
        XCTAssertTrue(msg?.isStreaming ?? false)
    }

    func testAppendStreamDelta_createsSessionIfAbsent() async throws {
        let storage = try makeStorage()
        // Don't pre-create the session — appendStreamDelta should auto-create.
        await storage.appendStreamDelta(messageId: "m1", sessionId: "phantom", delta: "A")

        let msgs = await storage.messages(sessionId: "phantom")
        XCTAssertEqual(msgs.count, 1)
    }

    // MARK: - finalizeStreaming

    func testFinalizeStreaming_flipsIsStreamingFalse() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "Done")
        await storage.finalizeStreaming(messageId: "m1")

        let msg = await storage.latestMessage(sessionId: "s1")
        XCTAssertFalse(msg?.isStreaming ?? true)
    }

    func testFinalizeStreaming_preservesContent() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "Alpha")
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "Beta")
        await storage.finalizeStreaming(messageId: "m1")

        let msg = await storage.latestMessage(sessionId: "s1")
        XCTAssertEqual(msg?.content, "AlphaBeta")
        XCTAssertFalse(msg?.isStreaming ?? true)
    }

    func testFinalizeStreaming_noopForNonexistentMessage() async throws {
        let storage = try makeStorage()
        // Should not crash
        await storage.finalizeStreaming(messageId: "ghost")
    }

    // MARK: - Mixed streaming and non-streaming messages

    func testMultipleStreamingMessages_independentContent() async throws {
        let storage = try makeStorage()
        await storage.upsertSession(SessionInfo(id: "s1", projectPath: "/a"))

        // Two independent assistant turns
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "First ")
        await storage.appendStreamDelta(messageId: "m1", sessionId: "s1", delta: "response")
        await storage.finalizeStreaming(messageId: "m1")

        await storage.appendStreamDelta(messageId: "m2", sessionId: "s1", delta: "Second ")
        await storage.appendStreamDelta(messageId: "m2", sessionId: "s1", delta: "response")
        await storage.finalizeStreaming(messageId: "m2")

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.count, 2)
        let m1 = msgs.first { $0.id == "m1" }
        let m2 = msgs.first { $0.id == "m2" }
        XCTAssertEqual(m1?.content, "First response")
        XCTAssertEqual(m2?.content, "Second response")
        XCTAssertFalse(m1?.isStreaming ?? true)
        XCTAssertFalse(m2?.isStreaming ?? true)
    }
}
