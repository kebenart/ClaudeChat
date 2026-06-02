import XCTest
@testable import ChatKit
@testable import ChatKitUI

// MARK: - Mock APIClient for AuthCoordinator tests

/// Wraps a real `APIClient` but intercepts HTTP via `MockURLProtocol`.
/// Re-uses the same mock infrastructure defined in `NetworkAPIClientTests.swift`.

// MARK: - Tests

final class NetworkAuthCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeDependencies() -> (client: APIClient, keychain: KeychainStore, profiles: ServerProfileStore, coordinator: AuthCoordinator) {
        // Build APIClient with MockURLProtocol
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = APIClient(baseURL: URL(string: "http://test.local")!, session: session)
        let keychain = KeychainStore()
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let profiles = ServerProfileStore(defaults: defaults)
        let coordinator = AuthCoordinator(client: client, keychain: keychain, profileStore: profiles)
        return (client, keychain, profiles, coordinator)
    }

    private func httpResponse(status: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Direct login

    func testLogin_directSuccess_setsLoggedInState() async throws {
        let (client, keychain, profiles, coordinator) = makeDependencies()

        // Register a profile
        let profileId = UUID()
        let profile = ServerProfile(id: profileId, url: URL(string: "http://test.local")!,
                                    displayName: "Test", username: "alice")
        profiles.upsert(profile)
        await coordinator.activate(profile: profile)

        MockURLProtocol.requestHandler = { req in
            let body = self.jsonData([
                "token": "jwt-direct",
                "user": ["id": 1, "username": "alice"],
            ])
            return (self.httpResponse(status: 200, url: req.url!), body)
        }

        let state = try await coordinator.login(username: "alice", password: "pw")
        if case let .loggedIn(user) = state {
            XCTAssertEqual(user.username, "alice")
        } else {
            XCTFail("Expected .loggedIn, got \(state)")
        }

        // Token should be persisted to keychain
        let savedToken = keychain.token(for: profileId)
        XCTAssertEqual(savedToken, "jwt-direct")

        // Token should be set on the client actor
        let clientToken = await client.token
        XCTAssertEqual(clientToken, "jwt-direct")

        // Cleanup
        keychain.setToken(nil, for: profileId)
    }

    // MARK: - TOTP flow

    func testLogin_totpRequired_thenSubmitCode_success() async throws {
        let (client, keychain, profiles, coordinator) = makeDependencies()

        let profileId = UUID()
        let profile = ServerProfile(id: profileId, url: URL(string: "http://test.local")!,
                                    displayName: "Test", username: "admin")
        profiles.upsert(profile)
        await coordinator.activate(profile: profile)

        // Step 1: login returns requirestotp
        var callCount = 0
        MockURLProtocol.requestHandler = { req in
            callCount += 1
            if req.url!.path.hasSuffix("/api/auth/login") && !req.url!.path.contains("/totp") {
                let body = self.jsonData([
                    "requiresTotp": true,
                    "totpToken": "pending-totp-token",
                ])
                return (self.httpResponse(status: 200, url: req.url!), body)
            } else if req.url!.path.hasSuffix("/api/auth/login/totp") {
                // Verify the body contains totpToken + code.
                // Note: URLProtocol may deliver the body via httpBodyStream, not httpBody.
                let bodyData: Data
                if let d = req.httpBody, !d.isEmpty {
                    bodyData = d
                } else if let stream = req.httpBodyStream {
                    var data = Data()
                    stream.open()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count > 0 { data.append(contentsOf: buffer[..<count]) }
                    }
                    stream.close()
                    bodyData = data
                } else {
                    bodyData = Data()
                }
                let bodyJson = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
                XCTAssertEqual(bodyJson["totpToken"] as? String, "pending-totp-token")
                XCTAssertEqual(bodyJson["code"] as? String, "123456")
                let body = self.jsonData([
                    "token": "jwt-totp",
                    "user": ["id": 10, "username": "admin"],
                ])
                return (self.httpResponse(status: 200, url: req.url!), body)
            }
            throw URLError(.badURL)
        }

        let stateAfterLogin = try await coordinator.login(username: "admin", password: "pw")
        if case .totpRequired = stateAfterLogin {
            // OK
        } else {
            XCTFail("Expected .totpRequired, got \(stateAfterLogin)")
        }

        // Step 2: submit TOTP code
        let stateAfterTOTP = try await coordinator.submitTOTP(code: "123456")
        if case let .loggedIn(user) = stateAfterTOTP {
            XCTAssertEqual(user.username, "admin")
        } else {
            XCTFail("Expected .loggedIn after TOTP, got \(stateAfterTOTP)")
        }

        let savedToken = keychain.token(for: profileId)
        XCTAssertEqual(savedToken, "jwt-totp")

        let clientToken = await client.token
        XCTAssertEqual(clientToken, "jwt-totp")

        // Cleanup
        keychain.setToken(nil, for: profileId)
    }

    // MARK: - TOTP: wrong code → totpFailed

    func testSubmitTOTP_wrongCode_throwsTotpFailed() async throws {
        let (_, _, profiles, coordinator) = makeDependencies()

        let profileId = UUID()
        let profile = ServerProfile(id: profileId, url: URL(string: "http://test.local")!,
                                    displayName: "Test", username: "admin")
        profiles.upsert(profile)
        await coordinator.activate(profile: profile)

        // First: get into TOTP required state
        MockURLProtocol.requestHandler = { req in
            if req.url!.path.hasSuffix("/api/auth/login") {
                let body = self.jsonData([
                    "requiresTotp": true,
                    "totpToken": "pending-token",
                ])
                return (self.httpResponse(status: 200, url: req.url!), body)
            } else if req.url!.path.hasSuffix("/api/auth/login/totp") {
                let body = self.jsonData(["error": "invalid code"])
                return (self.httpResponse(status: 401, url: req.url!), body)
            }
            throw URLError(.badURL)
        }

        _ = try await coordinator.login(username: "admin", password: "pw")

        do {
            _ = try await coordinator.submitTOTP(code: "000000")
            XCTFail("Expected totpFailed error")
        } catch ChatKitError.totpFailed(let msg) {
            XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: - submitTOTP without prior login → error

    func testSubmitTOTP_withoutLogin_throws() async throws {
        let (_, _, _, coordinator) = makeDependencies()

        do {
            _ = try await coordinator.submitTOTP(code: "123456")
            XCTFail("Expected error about no pending TOTP session")
        } catch {
            // Expected any error
        }
    }

    // MARK: - logout clears state

    func testLogout_clearsTokenAndState() async throws {
        let (client, keychain, profiles, coordinator) = makeDependencies()

        let profileId = UUID()
        let profile = ServerProfile(id: profileId, url: URL(string: "http://test.local")!,
                                    displayName: "Test", username: "user")
        profiles.upsert(profile)
        await coordinator.activate(profile: profile)

        // Seed a token
        keychain.setToken("existing-token", for: profileId)
        await client.setToken("existing-token")

        MockURLProtocol.requestHandler = { req in
            let body = self.jsonData(["success": true])
            return (self.httpResponse(status: 200, url: req.url!), body)
        }

        try await coordinator.logout()

        let state = await coordinator.authState
        if case .loggedOut = state { /* OK */ }
        else { XCTFail("Expected .loggedOut, got \(state)") }

        XCTAssertNil(keychain.token(for: profileId))
        let clientToken = await client.token
        XCTAssertNil(clientToken)
    }

    // MARK: - activate restores persisted token

    func testActivate_restoresPersistedToken() async throws {
        let (client, keychain, profiles, coordinator) = makeDependencies()

        let profileId = UUID()
        let profile = ServerProfile(id: profileId, url: URL(string: "http://test.local")!,
                                    displayName: "Test", username: "user")
        profiles.upsert(profile)
        keychain.setToken("restored-token", for: profileId)

        await coordinator.activate(profile: profile)

        let clientToken = await client.token
        XCTAssertEqual(clientToken, "restored-token")

        // Cleanup
        keychain.setToken(nil, for: profileId)
    }
}
