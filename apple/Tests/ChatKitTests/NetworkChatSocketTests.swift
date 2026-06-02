import XCTest
@testable import ChatKit
@testable import ChatKitUI

/// Tests the JSON parser (`ServerEvent.decode(from:rawData:)`) against fixture
/// JSON snippets that mirror real server frames.
final class NetworkChatSocketTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ dict: [String: Any]) -> (dict: [String: Any], data: Data) {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return (dict, data)
    }

    private func decode(_ dict: [String: Any]) -> ServerEvent {
        let (d, raw) = json(dict)
        return ServerEvent.decode(from: d, rawData: raw)
    }

    // MARK: - session_created (kind-keyed)

    func testDecodeSessionCreated_kind() {
        let event = decode([
            "kind": "session_created",
            "newSessionId": "sess-abc",
            "sessionId": "sess-abc",
            "id": "session_created_xxx",
            "timestamp": "2024-01-01T00:00:00Z",
            "provider": "claude",
        ])
        if case let .sessionCreated(sid) = event {
            XCTAssertEqual(sid, "sess-abc")
        } else {
            XCTFail("Expected .sessionCreated, got \(event)")
        }
    }

    func testDecodeSessionCreated_noNewSessionId() {
        // When newSessionId is absent, fall back to sessionId
        let event = decode([
            "kind": "session_created",
            "sessionId": "sess-xyz",
            "provider": "claude",
        ])
        if case let .sessionCreated(sid) = event {
            XCTAssertEqual(sid, "sess-xyz")
        } else {
            XCTFail("Expected .sessionCreated, got \(event)")
        }
    }

    // MARK: - stream_delta (kind-keyed)

    func testDecodeStreamDelta() {
        let event = decode([
            "kind": "stream_delta",
            "sessionId": "sess-1",
            "id": "msg-42",
            "content": "Hello, world",
            "provider": "claude",
        ])
        if case let .assistantText(sid, mid, text, isDelta) = event {
            XCTAssertEqual(sid, "sess-1")
            XCTAssertEqual(mid, "msg-42")
            XCTAssertEqual(text, "Hello, world")
            XCTAssertTrue(isDelta)
        } else {
            XCTFail("Expected .assistantText, got \(event)")
        }
    }

    // MARK: - permission_request (kind-keyed)

    func testDecodePermissionRequest() {
        let event = decode([
            "kind": "permission_request",
            "sessionId": "sess-perm",
            "requestId": "req-001",
            "toolName": "Bash",
            "input": ["command": "rm -rf /"],
            "provider": "claude",
        ])
        if case let .permissionRequest(sid, rid, toolName, input, _) = event {
            XCTAssertEqual(sid, "sess-perm")
            XCTAssertEqual(rid, "req-001")
            XCTAssertEqual(toolName, "Bash")
            // The input dict {"command":"rm -rf /"} is serialized to JSON string.
            // Accept any non-empty result — the exact JSON key order depends on platform.
            XCTAssertFalse(input.isEmpty, "input should be serialized to a non-empty string; got: \(input)")
            XCTAssertTrue(input.contains("command") || input.contains("rm"), "expected cmd in input; got: \(input)")
        } else {
            XCTFail("Expected .permissionRequest, got \(event)")
        }
    }

    func testDecodePermissionRequest_withTimeoutMs() {
        let event = decode([
            "kind": "permission_request",
            "sessionId": "sess-perm",
            "requestId": "req-002",
            "toolName": "Edit",
            "input": ["path": "/etc/hosts"],
            "timeoutMs": 30000,
            "provider": "claude",
        ])
        if case let .permissionRequest(_, _, toolName, _, timeout) = event {
            XCTAssertEqual(toolName, "Edit")
            XCTAssertEqual(timeout, 30000)
        } else {
            XCTFail("Expected .permissionRequest, got \(event)")
        }
    }

    // MARK: - permission_cancelled (kind-keyed)

    func testDecodePermissionCancelled() {
        let event = decode([
            "kind": "permission_cancelled",
            "sessionId": "sess-1",
            "requestId": "req-cancel",
            "reason": "User denied",
            "provider": "claude",
        ])
        if case let .permissionCancelled(sid, rid, reason) = event {
            XCTAssertEqual(sid, "sess-1")
            XCTAssertEqual(rid, "req-cancel")
            XCTAssertEqual(reason, "User denied")
        } else {
            XCTFail("Expected .permissionCancelled, got \(event)")
        }
    }

    // MARK: - complete (kind-keyed)

    func testDecodeComplete_normal() {
        let event = decode([
            "kind": "complete",
            "sessionId": "sess-done",
            "exitCode": 0,
            "aborted": false,
            "isNewSession": true,
            "provider": "claude",
        ])
        if case let .complete(sid, exitCode, aborted, isNew) = event {
            XCTAssertEqual(sid, "sess-done")
            XCTAssertEqual(exitCode, 0)
            XCTAssertFalse(aborted)
            XCTAssertTrue(isNew)
        } else {
            XCTFail("Expected .complete, got \(event)")
        }
    }

    func testDecodeComplete_aborted() {
        let event = decode([
            "kind": "complete",
            "sessionId": "sess-abort",
            "exitCode": 1,
            "aborted": true,
            "isNewSession": false,
            "provider": "claude",
        ])
        if case let .complete(_, _, aborted, _) = event {
            XCTAssertTrue(aborted)
        } else {
            XCTFail("Expected .complete, got \(event)")
        }
    }

    // MARK: - status (kind-keyed)

    func testDecodeStatus() {
        let event = decode([
            "kind": "status",
            "sessionId": "sess-stat",
            "text": "Thinking...",
            "provider": "claude",
        ])
        if case let .status(sid, text, budget) = event {
            XCTAssertEqual(sid, "sess-stat")
            XCTAssertEqual(text, "Thinking...")
            XCTAssertNil(budget)
        } else {
            XCTFail("Expected .status, got \(event)")
        }
    }

    func testDecodeStatus_withTokenBudget() {
        let event = decode([
            "kind": "status",
            "sessionId": "sess-stat",
            "text": "token_budget",
            "tokenBudget": ["remainingTokens": 50000],
            "provider": "claude",
        ])
        if case let .status(_, text, budget) = event {
            XCTAssertEqual(text, "token_budget")
            XCTAssertEqual(budget, 50000)
        } else {
            XCTFail("Expected .status, got \(event)")
        }
    }

    // MARK: - session-status (type-keyed, ad-hoc)

    func testDecodeSessionStatus_typeKeyed() {
        let event = decode([
            "type": "session-status",
            "sessionId": "sess-2",
            "isProcessing": true,
        ])
        if case let .sessionStatus(sid, isProcessing) = event {
            XCTAssertEqual(sid, "sess-2")
            XCTAssertTrue(isProcessing)
        } else {
            XCTFail("Expected .sessionStatus, got \(event)")
        }
    }

    // MARK: - error (type-keyed, ad-hoc)

    func testDecodeError_typeKeyed() {
        let event = decode([
            "type": "error",
            "error": "Something went wrong",
        ])
        if case let .error(sid, message) = event {
            XCTAssertNil(sid)
            XCTAssertEqual(message, "Something went wrong")
        } else {
            XCTFail("Expected .error, got \(event)")
        }
    }

    func testDecodeError_withSessionId() {
        let event = decode([
            "type": "error",
            "sessionId": "sess-err",
            "error": "Claude crashed",
        ])
        if case let .error(sid, message) = event {
            XCTAssertEqual(sid, "sess-err")
            XCTAssertEqual(message, "Claude crashed")
        } else {
            XCTFail("Expected .error, got \(event)")
        }
    }

    // MARK: - unknown → .raw

    func testDecodeUnknown_fallsToRaw() {
        let event = decode([
            "kind": "future_unknown_kind",
            "sessionId": "sess-x",
            "someField": 42,
        ])
        if case let .raw(kind, type_, _) = event {
            XCTAssertEqual(kind, "future_unknown_kind")
            XCTAssertNil(type_)
        } else {
            XCTFail("Expected .raw, got \(event)")
        }
    }

    func testDecodeUnknownTypeKeyed_fallsToRaw() {
        let event = decode([
            "type": "pending-permissions-response",
            "sessionId": "sess-x",
            "data": [],
        ])
        if case let .raw(kind, type_, _) = event {
            XCTAssertNil(kind)
            XCTAssertEqual(type_, "pending-permissions-response")
        } else {
            XCTFail("Expected .raw, got \(event)")
        }
    }

    // MARK: - stream_end

    func testDecodeStreamEnd() {
        let event = decode([
            "kind": "stream_end",
            "sessionId": "sess-end",
            "id": "msg-final",
            "provider": "claude",
        ])
        if case let .assistantText(sid, mid, text, isDelta) = event {
            XCTAssertEqual(sid, "sess-end")
            XCTAssertEqual(mid, "msg-final")
            XCTAssertEqual(text, "")
            XCTAssertFalse(isDelta)
        } else {
            XCTFail("Expected .assistantText(isDelta:false), got \(event)")
        }
    }

    // MARK: - tool_use

    func testDecodeToolUse() {
        let event = decode([
            "kind": "tool_use",
            "sessionId": "sess-tool",
            "id": "tool-msg-1",
            "toolName": "Read",
            "toolInput": ["path": "/tmp/file.txt"],
            "provider": "claude",
        ])
        if case let .toolUse(sid, mid, name, input) = event {
            XCTAssertEqual(sid, "sess-tool")
            XCTAssertEqual(mid, "tool-msg-1")
            XCTAssertEqual(name, "Read")
            XCTAssertFalse(input.isEmpty, "toolInput should be serialized; got: \(input)")
            XCTAssertTrue(input.contains("path") || input.contains("file.txt"), "expected path in input; got: \(input)")
        } else {
            XCTFail("Expected .toolUse, got \(event)")
        }
    }

    // MARK: - tool_result

    func testDecodeToolResult() {
        let event = decode([
            "kind": "tool_result",
            "sessionId": "sess-tool",
            "id": "tool-msg-1",
            "toolResult": [
                "content": "file contents here",
                "isError": false,
            ],
            "provider": "claude",
        ])
        if case let .toolResult(sid, toolUseId, output, isError) = event {
            XCTAssertEqual(sid, "sess-tool")
            XCTAssertEqual(toolUseId, "tool-msg-1")
            XCTAssertEqual(output, "file contents here")
            XCTAssertFalse(isError)
        } else {
            XCTFail("Expected .toolResult, got \(event)")
        }
    }
}
