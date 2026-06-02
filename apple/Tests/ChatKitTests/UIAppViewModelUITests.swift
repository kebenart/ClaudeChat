// Tests/ChatKitTests/UIAppViewModelUITests.swift
import XCTest
@testable import ChatKit
@testable import ChatKitUI

@MainActor
final class UIAppViewModelUITests: XCTestCase {

    private func makeVM() -> AppViewModel {
        AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
    }

    func testSwitchProfileSetsCurrentProfile() async {
        let vm = makeVM()
        let profile = ServerProfile(
            url: URL(string: "http://example.com")!,
            displayName: "Test",
            username: "alice"
        )
        await vm.switchProfile(profile)
        XCTAssertEqual(vm.currentServerProfile?.id, profile.id)
    }

    func testSwitchProfileWithNoTokenGoesLoggedOut() async {
        let vm = makeVM()
        let profile = ServerProfile(
            url: URL(string: "http://example.com")!,
            displayName: "Test",
            username: "alice"
        )
        // StubKeychain returns nil for any profile id
        await vm.switchProfile(profile)
        if case .loggedOut = vm.authState {
            // pass
        } else {
            XCTFail("Expected loggedOut when no token, got \(vm.authState)")
        }
    }

    func testCleanupUIResetsSessionState() async {
        let vm = makeVM()
        // Simulate logged-in state with sessions
        vm.authState = .loggedIn(user: User(id: 1, username: "test"))
        vm.sessions = [SessionInfo(id: "s1", projectPath: "/p")]
        vm.currentSessionId = "s1"
        vm.unreadCounts = ["s1": 3]

        await vm.cleanupUI()

        XCTAssertEqual(vm.sessions.count, 0)
        XCTAssertNil(vm.currentSessionId)
        XCTAssertEqual(vm.unreadCounts.count, 0)
    }

    func testLogoutAndCleanupResetsState() async {
        let vm = makeVM()
        vm.authState = .loggedIn(user: User(id: 1, username: "test"))
        vm.sessions = [SessionInfo(id: "s1", projectPath: "/p")]
        vm.currentSessionId = "s1"
        vm.unreadCounts = ["s1": 2]

        await vm.logoutAndCleanup()

        if case .loggedOut = vm.authState {
            // pass
        } else {
            XCTFail("Expected loggedOut, got \(vm.authState)")
        }
        XCTAssertEqual(vm.sessions.count, 0)
        XCTAssertNil(vm.currentSessionId)
        XCTAssertEqual(vm.unreadCounts.count, 0)
    }
}
