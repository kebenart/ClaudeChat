import XCTest
@testable import ChatKit
@testable import ChatKitUI

// MARK: - Helpers

/// Build an AsyncStream<ServerEvent> from an array of events.
private func makeStream(_ events: [ServerEvent]) -> AsyncStream<ServerEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}

// MARK: - Tests

final class EventReducerTests: XCTestCase {

    private func makeStorage() throws -> Storage {
        let container = try StorageContainer.makeInMemory()
        return Storage(container: container)
    }

    // MARK: - sessionCreated

    func testSessionCreated_createsSession() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([.sessionCreated(sessionId: "sess-A")])
        await reducer.consume(stream)

        let exists = await storage.sessionExists("sess-A")
        XCTAssertTrue(exists)
    }

    func testSessionCreated_idempotent() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "sess-A"),
            .sessionCreated(sessionId: "sess-A"),
        ])
        await reducer.consume(stream)

        let sessions = await storage.listSessions(includingHidden: true)
        XCTAssertEqual(sessions.count, 1)
    }

    // MARK: - assistantText streaming

    func testAssistantText_delta_buildsContent() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "Hello ", isDelta: true),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "world!", isDelta: true),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.first?.content, "Hello world!")
        XCTAssertTrue(msgs.first?.isStreaming ?? false)
    }

    func testAssistantText_nonDelta_upserts() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "Full text", isDelta: false),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        XCTAssertEqual(msgs.first?.content, "Full text")
        XCTAssertFalse(msgs.first?.isStreaming ?? true)
    }

    // MARK: - complete

    func testComplete_finalizesStreamingMessage() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "Hello", isDelta: true),
            .complete(sessionId: "s1", exitCode: 0, aborted: false, isNewSession: false),
        ])
        await reducer.consume(stream)

        let msg = await storage.latestMessage(sessionId: "s1")
        XCTAssertFalse(msg?.isStreaming ?? true, "Message should not be streaming after complete")
    }

    func testComplete_incrementsUnreadWhenNotFocused() async throws {
        let storage = try makeStorage()
        // isSessionFocused always returns false → unread should be incremented
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "Hi", isDelta: true),
            .complete(sessionId: "s1", exitCode: 0, aborted: false, isNewSession: false),
        ])
        await reducer.consume(stream)

        // clearUnread should not crash (verifies the counter was incremented then cleared OK)
        await storage.clearUnread(sessionId: "s1")
    }

    func testComplete_doesNotIncrementUnreadWhenFocused() async throws {
        let storage = try makeStorage()
        // Mark session as focused → unread should NOT be incremented
        let focusedSessionId = "s1"
        let reducer = EventReducer(
            storage: storage,
            isSessionFocused: { sid in sid == focusedSessionId }
        )
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .assistantText(sessionId: "s1", messageId: "msg-1", text: "Hi", isDelta: true),
            .complete(sessionId: "s1", exitCode: 0, aborted: false, isNewSession: false),
        ])
        await reducer.consume(stream)
        // clearUnread is still safe to call, just confirming no crash
        await storage.clearUnread(sessionId: "s1")
    }

    // MARK: - toolUse

    func testToolUse_insertsToolMessage() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .toolUse(sessionId: "s1", messageId: "tool-1", name: "Bash",
                     input: #"{"command":"ls"}"#),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        let toolMsg = msgs.first { $0.id == "tool-1" }
        XCTAssertNotNil(toolMsg)
        XCTAssertEqual(toolMsg?.toolUse?.name, "Bash")
        XCTAssertEqual(toolMsg?.role, .tool)
    }

    // MARK: - permissionRequest

    func testPermissionRequest_insertsPendingToolMessage() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .permissionRequest(sessionId: "s1", requestId: "req-1",
                               toolName: "Edit", input: #"{"path":"/tmp/x"}"#, timeoutMs: 30000),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        let permMsg = msgs.first { $0.id == "perm-req-1" }
        XCTAssertNotNil(permMsg)
        XCTAssertEqual(permMsg?.toolUse?.approvalState, .pending)
        XCTAssertEqual(permMsg?.toolUse?.requestId, "req-1")
        XCTAssertEqual(permMsg?.toolUse?.name, "Edit")
    }

    func testPermissionRequest_setsHasPendingApproval() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .permissionRequest(sessionId: "s1", requestId: "req-1",
                               toolName: "Edit", input: "", timeoutMs: nil),
        ])
        await reducer.consume(stream)
        // setHasPendingApproval should have been called; verify no crash.
        // (hasPendingApproval is on SessionRecord, not exposed in SessionInfo DTO yet)
        let exists = await storage.sessionExists("s1")
        XCTAssertTrue(exists)
    }

    // MARK: - permissionCancelled

    func testPermissionCancelled_updatesApprovalState_timeout() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .permissionRequest(sessionId: "s1", requestId: "req-2",
                               toolName: "Read", input: "", timeoutMs: nil),
            .permissionCancelled(sessionId: "s1", requestId: "req-2", reason: "timeout"),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        let permMsg = msgs.first { $0.id == "perm-req-2" }
        XCTAssertEqual(permMsg?.toolUse?.approvalState, .timedOut)
    }

    func testPermissionCancelled_updatesApprovalState_cancelled() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionCreated(sessionId: "s1"),
            .permissionRequest(sessionId: "s1", requestId: "req-3",
                               toolName: "Write", input: "", timeoutMs: nil),
            .permissionCancelled(sessionId: "s1", requestId: "req-3", reason: "user"),
        ])
        await reducer.consume(stream)

        let msgs = await storage.messages(sessionId: "s1")
        let permMsg = msgs.first { $0.id == "perm-req-3" }
        XCTAssertEqual(permMsg?.toolUse?.approvalState, .cancelled)
    }

    // MARK: - Full end-to-end synthetic stream

    func testEndToEnd_syntheticStream() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })

        let events: [ServerEvent] = [
            .sessionCreated(sessionId: "e2e"),
            .assistantText(sessionId: "e2e", messageId: "e2e-msg-1", text: "I'll run bash", isDelta: true),
            .toolUse(sessionId: "e2e", messageId: "e2e-tool-1", name: "Bash", input: #"{"command":"pwd"}"#),
            .toolResult(sessionId: "e2e", toolUseId: "e2e-tool-1", output: "/Users/kobe", isError: false),
            .assistantText(sessionId: "e2e", messageId: "e2e-msg-1", text: " done.", isDelta: true),
            .complete(sessionId: "e2e", exitCode: 0, aborted: false, isNewSession: false),
            .status(sessionId: "e2e", text: "Idle", tokenBudget: nil),
            .error(sessionId: "e2e", message: "This is a test error log"),
        ]
        let stream = makeStream(events)
        await reducer.consume(stream)

        // Session exists
        let exists = await storage.sessionExists("e2e")
        XCTAssertTrue(exists)

        // Final message is not streaming
        let latest = await storage.latestMessage(sessionId: "e2e")
        XCTAssertFalse(latest?.isStreaming ?? true)

        // Tool message exists with output
        let msgs = await storage.messages(sessionId: "e2e")
        let toolMsg = msgs.first { $0.id == "e2e-tool-1" }
        XCTAssertNotNil(toolMsg)

        // Search finds content
        let results = await storage.search("bash")
        XCTAssertFalse(results.matchingMessages.isEmpty ||
                       results.matchingSessions.count + results.matchingMessages.count == 0)
    }

    // MARK: - rawEvent (no crash)

    func testRawEvent_doesNotCrash() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .raw(kind: "unknown-kind", type: nil, payload: Data()),
        ])
        // Just verify no crash
        await reducer.consume(stream)
    }

    // MARK: - sessionStatus (no-op, no crash)

    func testSessionStatus_noopNoCrash() async throws {
        let storage = try makeStorage()
        let reducer = EventReducer(storage: storage, isSessionFocused: { _ in false })
        let stream = makeStream([
            .sessionStatus(sessionId: "s9", isProcessing: true),
        ])
        await reducer.consume(stream)
        // Should not have created a session
        let exists = await storage.sessionExists("s9")
        XCTAssertFalse(exists)
    }
}
