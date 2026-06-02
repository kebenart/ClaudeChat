import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class ImAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IMMockURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://test.local")!, session: URLSession(configuration: config))
    }

    override func tearDown() {
        IMMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchImSyncParsesResponseAndSendsCursorAndAuth() async throws {
        let client = makeClient()
        await client.setToken("jwt-abc")
        IMMockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.path, "/api/im/sync")
            XCTAssertTrue(req.url?.query?.contains("since=7") ?? false)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-abc")
            let body = #"{"messages":[],"conversations":[],"readCursors":[],"cursor":9,"hasMore":false}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let resp = try await client.fetchImSync(since: 7)
        XCTAssertEqual(resp.cursor, 9)
        XCTAssertFalse(resp.hasMore)
    }

    func testPostImReadSendsMethodAndPath() async throws {
        let client = makeClient()
        IMMockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/im/conversations/c1/read")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, #"{"ok":true}"#.data(using: .utf8)!)
        }
        try await client.postImRead(conversationId: "c1", deviceId: "devA", lastReadSeq: 3)
    }

    func testFetchImMessagesUnwrapsAndPages() async throws {
        let client = makeClient()
        IMMockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.path, "/api/im/conversations/c1/messages")
            XCTAssertTrue(req.url?.query?.contains("numBefore=40") ?? false)
            let body = #"{"messages":[{"id":"a1","conversationId":"c1","seq":2,"role":"assistant","kind":"result","content":"yo","createdAt":1}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let msgs = try await client.fetchImMessages(conversationId: "c1", anchor: nil, numBefore: 40, numAfter: 0)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].id, "a1")
    }
}

final class IMMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = IMMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
