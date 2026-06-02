import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class ImDTOsTests: XCTestCase {
    func testDecodeSyncResponseWithToolTrace() throws {
        let json = """
        {
          "messages": [
            {"id":"s1","conversationId":"c1","seq":1,"role":"user","kind":"text","content":"hi","createdAt":10},
            {"id":"a1","conversationId":"c1","seq":2,"role":"assistant","kind":"result","content":"yo","createdAt":20,
             "toolTrace":{"count":2,"rawRefStart":"x","rawRefEnd":"y"}}
          ],
          "conversations": [
            {"id":"c1","contactId":"/r","providerId":"claude","title":"C1","lastMessagePreview":"yo",
             "lastSeq":2,"lastActivityAt":20,"isPinned":false,"isMuted":false}
          ],
          "readCursors": [{"conversationId":"c1","deviceId":"devA","lastReadSeq":1}],
          "cursor": 2,
          "hasMore": false
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(ImSyncResponse.self, from: json)
        XCTAssertEqual(resp.cursor, 2)
        XCTAssertFalse(resp.hasMore)
        XCTAssertEqual(resp.messages.count, 2)
        XCTAssertNil(resp.messages[0].toolTrace)
        XCTAssertEqual(resp.messages[1].toolTrace?.count, 2)
        XCTAssertEqual(resp.messages[1].toolTrace?.rawRefEnd, "y")
        XCTAssertEqual(resp.conversations[0].lastSeq, 2)
        XCTAssertEqual(resp.readCursors[0].deviceId, "devA")
    }
}
