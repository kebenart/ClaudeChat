import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class ImEventsTests: XCTestCase {
    private func decode(_ s: String) -> ServerEvent {
        let data = s.data(using: .utf8)!
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ServerEvent.decode(from: json, rawData: data)
    }

    func testDecodeImMessage() {
        let ev = decode("""
        {"type":"im:message","message":{"id":"a1","conversationId":"c1","seq":2,"role":"assistant","kind":"result","content":"done","createdAt":9}}
        """)
        guard case let .imMessage(conversationId, message) = ev else { return XCTFail("expected imMessage, got \(ev)") }
        XCTAssertEqual(conversationId, "c1")
        XCTAssertEqual(message.id, "a1")
        XCTAssertEqual(message.seq, 2)
        XCTAssertEqual(message.content, "done")
    }

    func testDecodeImRead() {
        let ev = decode("""
        {"type":"im:read","conversationId":"c1","deviceId":"phone","lastReadSeq":7}
        """)
        guard case let .imRead(conversationId, deviceId, lastReadSeq) = ev else { return XCTFail("expected imRead") }
        XCTAssertEqual(conversationId, "c1")
        XCTAssertEqual(deviceId, "phone")
        XCTAssertEqual(lastReadSeq, 7)
    }

    func testDecodeImPoke() {
        let ev = decode(#"{"type":"im:poke","since":42}"#)
        guard case let .imPoke(since) = ev else { return XCTFail("expected imPoke") }
        XCTAssertEqual(since, 42)
    }
}
