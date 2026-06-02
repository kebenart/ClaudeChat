// Tests/ChatKitTests/UITOTPSetupTests.swift
import XCTest
@testable import ChatKit
@testable import ChatKitUI

// MARK: - QR code generation tests

final class UITOTPSetupTests: XCTestCase {

    // MARK: - qrCodeImage helper

    func testQrCodeImageReturnsNonNilForValidURI() {
        let uri = "otpauth://totp/ClaudeChat%3Atest?secret=JBSWY3DPEHPK3PXP&issuer=ClaudeChat"
        let img = qrCodeImage(from: uri, size: 200)
        XCTAssertNotNil(img, "Should produce an NSImage for a valid otpauth URI")
    }

    func testQrCodeImageSizeMatchesRequest() {
        let uri = "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP"
        let size: CGFloat = 150
        guard let img = qrCodeImage(from: uri, size: size) else {
            XCTFail("qrCodeImage returned nil")
            return
        }
        XCTAssertEqual(img.size.width,  size, accuracy: 1.0)
        XCTAssertEqual(img.size.height, size, accuracy: 1.0)
    }

    func testQrCodeImageDifferentSizes() {
        let uri = "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP"
        let small = qrCodeImage(from: uri, size: 100)
        let large = qrCodeImage(from: uri, size: 300)
        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertNotEqual(small?.size.width, large?.size.width)
    }

    // MARK: - AppViewModel TOTP setup flow

    @MainActor
    func testLoginWithTotpDisabledTransitionsTotpSetupRequired() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        // StubAPIClient returns totpEnabled: false for non-admin users
        await vm.login(username: "alice", password: "any")
        if case .totpSetupRequired = vm.authState {
            // pass
        } else {
            XCTFail("Expected .totpSetupRequired, got \(vm.authState)")
        }
    }

    @MainActor
    func testBeginTotpSetupPopulatesArtifacts() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        vm.authState = .totpSetupRequired(user: User(id: 1, username: "test"))
        await vm.beginTotpSetup()
        XCTAssertNotNil(vm.totpSetupArtifacts, "Artifacts should be set after beginTotpSetup")
        XCTAssertFalse(vm.totpSetupArtifacts?.uri.isEmpty ?? true)
        XCTAssertFalse(vm.totpSetupArtifacts?.secret.isEmpty ?? true)
        XCTAssertFalse(vm.totpSetupArtifacts?.recovery.isEmpty ?? true)
    }

    @MainActor
    func testSkipTotpSetupTransitionsToLoggedIn() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        let user = User(id: 1, username: "test", totpEnabled: false)
        vm.authState = .totpSetupRequired(user: user)
        vm.skipTotpSetup()
        if case .loggedIn = vm.authState {
            // pass
        } else {
            XCTFail("Expected .loggedIn after skipTotpSetup, got \(vm.authState)")
        }
        XCTAssertNil(vm.totpSetupArtifacts, "Artifacts should be cleared after skip")
    }

    @MainActor
    func testVerifyTotpSetupWithValidCodeTransitionsToLoggedIn() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        let user = User(id: 1, username: "test", totpEnabled: false)
        vm.authState = .totpSetupRequired(user: user)
        await vm.beginTotpSetup()
        XCTAssertNotNil(vm.totpSetupArtifacts)

        await vm.verifyTotpSetup(code: "123456")

        if case .loggedIn(let loggedInUser) = vm.authState {
            XCTAssertEqual(loggedInUser.username, "test")
            XCTAssertEqual(loggedInUser.totpEnabled, true)
        } else {
            XCTFail("Expected .loggedIn after verifyTotpSetup, got \(vm.authState)")
        }
        XCTAssertNil(vm.totpSetupArtifacts, "Artifacts should be cleared after verify")
    }

    @MainActor
    func testVerifyTotpSetupWithInvalidCodeShowsError() async {
        let vm = AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
        let user = User(id: 1, username: "test", totpEnabled: false)
        vm.authState = .totpSetupRequired(user: user)
        await vm.beginTotpSetup()

        // StubAPIClient rejects non-6-digit codes
        await vm.verifyTotpSetup(code: "abc")

        XCTAssertNotNil(vm.loginError, "Should set loginError for invalid code")
        if case .totpSetupRequired = vm.authState {
            // pass — should NOT have transitioned away
        } else {
            XCTFail("Should stay in .totpSetupRequired on error, got \(vm.authState)")
        }
    }
}
