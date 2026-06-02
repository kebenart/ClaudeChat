import XCTest
@testable import ChatKit
@testable import ChatKitUI

/// Round-trip write/read/delete tests for `KeychainStore`.
final class NetworkKeychainStoreTests: XCTestCase {

    // Use a fresh profile ID for each test to avoid cross-test pollution.
    private var store: KeychainStore!
    private var profileId: UUID!

    override func setUp() {
        super.setUp()
        store = KeychainStore()
        profileId = UUID()
    }

    override func tearDown() {
        // Clean up: delete any token we may have written.
        store.setToken(nil, for: profileId)
        super.tearDown()
    }

    // MARK: - Tests

    func testReadNonexistentToken_returnsNil() {
        let token = store.token(for: profileId)
        XCTAssertNil(token, "Expected nil for unknown profileId")
    }

    func testWriteThenRead_roundTrip() {
        store.setToken("my-secret-token", for: profileId)
        let token = store.token(for: profileId)
        XCTAssertEqual(token, "my-secret-token")
    }

    func testOverwrite_updatesValue() {
        store.setToken("token-v1", for: profileId)
        store.setToken("token-v2", for: profileId)
        let token = store.token(for: profileId)
        XCTAssertEqual(token, "token-v2")
    }

    func testDelete_nilRemovesEntry() {
        store.setToken("to-delete", for: profileId)
        store.setToken(nil, for: profileId)
        let token = store.token(for: profileId)
        XCTAssertNil(token, "Token should be nil after deletion")
    }

    func testDeleteNonexistent_doesNotCrash() {
        // Should not throw or crash
        store.setToken(nil, for: profileId)
        XCTAssertNil(store.token(for: profileId))
    }

    func testDifferentProfiles_areIsolated() {
        let id1 = UUID()
        let id2 = UUID()
        defer {
            store.setToken(nil, for: id1)
            store.setToken(nil, for: id2)
        }
        store.setToken("token-for-1", for: id1)
        store.setToken("token-for-2", for: id2)
        XCTAssertEqual(store.token(for: id1), "token-for-1")
        XCTAssertEqual(store.token(for: id2), "token-for-2")
    }

    func testUnicodeToken_roundTrip() {
        let unicodeToken = "jwt_héllo_wörld_🚀"
        store.setToken(unicodeToken, for: profileId)
        XCTAssertEqual(store.token(for: profileId), unicodeToken)
    }

    func testLongToken_roundTrip() {
        let longToken = String(repeating: "a", count: 4096)
        store.setToken(longToken, for: profileId)
        XCTAssertEqual(store.token(for: profileId), longToken)
    }
}
