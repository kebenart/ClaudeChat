import Foundation

// MARK: - AuthCoordinator

/// Orchestrates the full login flow:
///
/// 1. Caller invokes `login(username:password:)`.
/// 2. If the backend responds with `requirestotp: true`, the coordinator returns
///    `.totpRequired` and saves the pending TOTP token internally.
/// 3. Caller passes the 6-digit code to `submitTOTP(code:)`.
/// 4. On success the token is persisted to Keychain and injected into `APIClient`.
///
/// Uses the shared `AuthState` defined in `AppViewModel.swift`:
///   `.loggedOut` / `.totpRequired(totpToken:)` / `.loggedIn(user:)`
///
/// All state mutations happen inside the `actor` so callers can safely `await`.
public actor AuthCoordinator {

    // MARK: - Dependencies

    private let client: APIClient
    private let keychain: any KeychainStoreProtocol
    private let profileStore: any ServerProfileStoreProtocol

    // MARK: - State

    public private(set) var authState: AuthState = .loggedOut

    /// The profile being logged in to.
    private var activeProfileId: UUID?

    // MARK: - Init

    public init(client: APIClient,
                keychain: any KeychainStoreProtocol,
                profileStore: any ServerProfileStoreProtocol) {
        self.client = client
        self.keychain = keychain
        self.profileStore = profileStore
    }

    // MARK: - Public API

    /// Configure which server profile is active and restore any persisted token.
    public func activate(profile: ServerProfile) async {
        activeProfileId = profile.id
        await client.setBaseURL(profile.url)
        if let token = keychain.token(for: profile.id) {
            await client.setToken(token)
        }
    }

    /// Begin the login flow with username + password.
    ///
    /// Returns the new `AuthState`:
    /// - `.loggedIn(user:)` on immediate success (no TOTP).
    /// - `.totpRequired(totpToken:)` when the server demands a second factor.
    @discardableResult
    public func login(username: String, password: String) async throws -> AuthState {
        let response = try await client.login(username: username, password: password)

        if response.requiresTotp == true, let totpToken = response.totpToken {
            authState = .totpRequired(totpToken: totpToken)
            return authState
        }

        guard let token = response.token else {
            throw ChatKitError.other("Login response contained no token")
        }
        let user = response.user ?? User(id: 0, username: username)
        await _finalize(token: token, user: user)
        return authState
    }

    /// Submit the 6-digit TOTP code after `login` returned `.totpRequired`.
    ///
    /// Throws `ChatKitError.totpFailed` if the code is wrong.
    @discardableResult
    public func submitTOTP(code: String) async throws -> AuthState {
        guard let totpToken = await client.pendingTotpToken else {
            throw ChatKitError.other("No pending TOTP session; call login(username:password:) first")
        }

        let response: LoginResponse
        do {
            response = try await client.loginWithTOTP(totpToken: totpToken, code: code)
        } catch ChatKitError.httpStatus(let httpCode, _) where httpCode == 401 {
            throw ChatKitError.totpFailed(message: "Invalid TOTP code")
        } catch ChatKitError.httpStatus(let httpCode, let body) where httpCode == 429 {
            throw ChatKitError.totpFailed(message: "Too many attempts: \(body)")
        }

        guard let token = response.token else {
            throw ChatKitError.totpFailed(message: "TOTP verification returned no token")
        }
        let user = response.user ?? User(id: 0, username: "")
        await _finalize(token: token, user: user)
        return authState
    }

    /// Sign out: clear the token from Keychain and `APIClient`.
    public func logout() async throws {
        try? await client.logout()
        if let profileId = activeProfileId {
            keychain.setToken(nil, for: profileId)
        }
        await client.setToken(nil)
        authState = .loggedOut
    }

    // MARK: - Private

    private func _finalize(token: String, user: User) async {
        if let profileId = activeProfileId {
            keychain.setToken(token, for: profileId)
            // Update lastUsedAt on the stored profile
            if var profile = profileStore.list().first(where: { $0.id == profileId }) {
                profile = ServerProfile(
                    id: profile.id, url: profile.url,
                    displayName: profile.displayName,
                    username: user.username,
                    lastUsedAt: Date()
                )
                profileStore.upsert(profile)
            }
        }
        await client.setToken(token)
        authState = .loggedIn(user: user)
    }
}
