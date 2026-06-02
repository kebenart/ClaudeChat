import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class SmokeTests: XCTestCase {
    func testServerProfileRoundTrip() throws {
        let p = ServerProfile(url: URL(string: "https://cli.example.com")!,
                              displayName: "Home",
                              username: "kobe")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(decoded.username, "kobe")
        XCTAssertEqual(decoded.id, p.id)
    }

    func testChatMessageRoundTrip() throws {
        let m = ChatMessage(id: "msg-1", sessionId: "sess-1", role: .assistant,
                            content: "hi", isStreaming: true)
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertTrue(decoded.isStreaming)
    }

    func testClientEventWirePayload_claudeCommand() throws {
        let ev = ClientEvent.claudeCommand(prompt: "hello", sessionId: "abc",
                                           projectPath: "/tmp/x", modelId: nil, resume: true)
        let payload = ev.wirePayload()
        XCTAssertEqual(payload["type"] as? String, "claude-command")
        XCTAssertEqual(payload["command"] as? String, "hello")
        let opts = payload["options"] as? [String: Any]
        XCTAssertEqual(opts?["sessionId"] as? String, "abc")
        XCTAssertEqual(opts?["resume"] as? Bool, true)
        XCTAssertNil(opts?["modelId"])
    }

    func testClientEventWirePayload_toolApproval() throws {
        let ev = ClientEvent.toolApprovalResponse(requestId: "rq-1", allow: false, updatedInput: nil)
        let payload = ev.wirePayload()
        XCTAssertEqual(payload["type"] as? String, "claude-permission-response")
        XCTAssertEqual(payload["requestId"] as? String, "rq-1")
        XCTAssertEqual(payload["allow"] as? Bool, false)
    }
}
