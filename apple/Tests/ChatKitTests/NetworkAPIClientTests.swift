import XCTest
@testable import ChatKit
@testable import ChatKitUI

// MARK: - Mock URLProtocol

/// Intercepts URLRequests and returns canned responses without hitting the network.
final class MockURLProtocol: URLProtocol {

    // Registered handlers — keyed by URL path.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeClient() -> APIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return APIClient(baseURL: URL(string: "http://test.local")!, session: session)
}

private func httpResponse(status: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

private func jsonData(_ dict: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
}

// MARK: - Tests

final class NetworkAPIClientTests: XCTestCase {

    // MARK: - Login: direct success

    func testLogin_success() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let url = req.url!
            XCTAssertTrue(url.path.hasSuffix("/api/auth/login"))
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = jsonData([
                "token": "jwt-abc",
                "user": ["id": 42, "username": "alice"],
            ])
            return (httpResponse(status: 200, url: url), body)
        }

        let response = try await client.login(username: "alice", password: "secret")
        XCTAssertEqual(response.token, "jwt-abc")
        XCTAssertEqual(response.user?.username, "alice")
        XCTAssertNil(response.requiresTotp)
    }

    // MARK: - Login: TOTP required

    func testLogin_totpRequired() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let body = jsonData([
                "requiresTotp": true,
                "totpToken": "totp-pending-token",
            ])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        let response = try await client.login(username: "admin", password: "pw")
        XCTAssertTrue(response.requiresTotp == true)
        // The pending TOTP token should be stored on the client actor
        let pending = await client.pendingTotpToken
        XCTAssertEqual(pending, "totp-pending-token")
    }

    // MARK: - 401 → ChatKitError.notAuthenticated

    func testRequest_401_throwsNotAuthenticated() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let body = jsonData(["error": "Unauthorized"])
            return (httpResponse(status: 401, url: req.url!), body)
        }

        do {
            _ = try await client.authStatus()
            XCTFail("Expected notAuthenticated error")
        } catch ChatKitError.notAuthenticated {
            // Expected
        }
    }

    // MARK: - X-Refreshed-Token header handling

    func testRefreshedTokenHeader_updatesStoredToken() async throws {
        let client = makeClient()
        await client.setToken("old-token")

        MockURLProtocol.requestHandler = { req in
            // Verify old token is sent
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer old-token")
            let headers = ["X-Refreshed-Token": "new-refreshed-token"]
            let body = jsonData(["needsSetup": false])
            return (httpResponse(status: 200, url: req.url!, headers: headers), body)
        }

        _ = try await client.authStatus()
        let token = await client.token
        XCTAssertEqual(token, "new-refreshed-token")
    }

    // MARK: - Bearer token injection

    func testBearerTokenInjected() async throws {
        let client = makeClient()
        await client.setToken("bearer-xyz")

        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-xyz")
            let body = jsonData(["user": ["id": 1, "username": "u"]])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        _ = try await client.currentUser()
    }

    // MARK: - No token → no Authorization header

    func testNoToken_noAuthHeader() async throws {
        let client = makeClient()
        // token is nil by default

        MockURLProtocol.requestHandler = { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            let body = jsonData(["needsSetup": true])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        _ = try await client.authStatus()
    }

    // MARK: - HTTP 500 → ChatKitError.httpStatus

    func testRequest_500_throwsHttpStatus() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let body = jsonData(["error": "Internal server error"])
            return (httpResponse(status: 500, url: req.url!), body)
        }

        do {
            _ = try await client.authStatus()
            XCTFail("Should have thrown")
        } catch ChatKitError.httpStatus(let code, _) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - fetchProjects

    func testFetchProjects() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/api/projects"))
            let projectArray: [[String: Any]] = [
                [
                    "projectId": "proj-1",
                    "path": "/home/user/project",
                    "displayName": "My Project",
                    "fullPath": "/home/user/project",
                ],
            ]
            let body = try! JSONSerialization.data(withJSONObject: projectArray)
            return (httpResponse(status: 200, url: req.url!), body)
        }

        let projects = try await client.fetchProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "proj-1")
        XCTAssertEqual(projects[0].displayName, "My Project")
        XCTAssertEqual(projects[0].path, "/home/user/project")
    }

    // MARK: - fetchSessions

    func testFetchSessions() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/api/sessions/active"))
            let body = jsonData([
                "live": [
                    [
                        "id": "sess-live-1",
                        "title": "Active Session",
                        "cwd": "/tmp/project",
                        "mtime": 1700000000000.0,
                    ],
                ],
                "windowMin": 5,
            ])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        let sessions = try await client.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "sess-live-1")
        XCTAssertEqual(sessions[0].projectPath, "/tmp/project")
        XCTAssertTrue(sessions[0].isActive == true)
    }

    // MARK: - setBaseURL

    func testSetBaseURL_usedForRequests() async throws {
        let client = makeClient()
        await client.setBaseURL(URL(string: "http://other-server.local:8080")!)

        MockURLProtocol.requestHandler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasPrefix("http://other-server.local:8080"))
            let body = jsonData(["needsSetup": false])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        _ = try await client.authStatus()
    }

    // MARK: - fetchProjects — richer backend shape (with sessions + isStarred)

    func testFetchProjects_withNestedSessionsAndIsStarred() async throws {
        // The real backend returns the full ProjectListItem shape that includes
        // nested `sessions` and `sessionMeta`. Our decoder must tolerate those
        // extra fields and still map the top-level project fields correctly.
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let projectArray: [[String: Any]] = [
                [
                    "projectId": "proj-rich",
                    "path": "/home/user/rich-project",
                    "displayName": "Rich Project",
                    "fullPath": "/home/user/rich-project",
                    "isStarred": true,
                    "sessions": [
                        ["id": "sess-a", "summary": "First session", "messageCount": 3, "lastActivity": "2024-01-01T00:00:00Z"],
                    ],
                    "sessionMeta": ["hasMore": false, "total": 1],
                ],
            ]
            let body = try! JSONSerialization.data(withJSONObject: projectArray)
            return (httpResponse(status: 200, url: req.url!), body)
        }

        let projects = try await client.fetchProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "proj-rich")
        XCTAssertEqual(projects[0].displayName, "Rich Project")
        XCTAssertEqual(projects[0].path, "/home/user/rich-project")
        XCTAssertEqual(projects[0].fullPath, "/home/user/rich-project")
    }

    // MARK: - fetchProjects — multiple projects

    func testFetchProjects_multipleProjects() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            let projectArray: [[String: Any]] = [
                ["projectId": "p1", "path": "/a", "displayName": "Alpha", "fullPath": "/a", "isStarred": false, "sessions": [], "sessionMeta": ["hasMore": false, "total": 0]],
                ["projectId": "p2", "path": "/b", "displayName": "Beta",  "fullPath": "/b", "isStarred": true,  "sessions": [], "sessionMeta": ["hasMore": false, "total": 0]],
            ]
            let body = try! JSONSerialization.data(withJSONObject: projectArray)
            return (httpResponse(status: 200, url: req.url!), body)
        }

        let projects = try await client.fetchProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].id, "p1")
        XCTAssertEqual(projects[1].id, "p2")
    }

    // MARK: - wsURL helper

    @MainActor
    func testWsURLConversion_http() async {
        // wsURL helper lives on AppViewModel; test it indirectly by verifying the
        // expected transform.
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        let http = URL(string: "http://localhost:3001")!
        let ws = vm.wsURL(from: http)
        XCTAssertEqual(ws?.scheme, "ws")
        XCTAssertEqual(ws?.path, "/ws")
        XCTAssertEqual(ws?.host, "localhost")
        XCTAssertEqual(ws?.port, 3001)
    }

    @MainActor
    func testWsURLConversion_https() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        let https = URL(string: "https://example.com")!
        let ws = vm.wsURL(from: https)
        XCTAssertEqual(ws?.scheme, "wss")
        XCTAssertTrue(ws?.absoluteString.hasSuffix("/ws") ?? false)
    }

    // MARK: - logout

    func testLogout_sendsPost() async throws {
        let client = makeClient()
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url!.path.hasSuffix("/api/auth/logout"))
            let body = jsonData(["success": true])
            return (httpResponse(status: 200, url: req.url!), body)
        }

        // Should not throw
        try await client.logout()
    }
}
