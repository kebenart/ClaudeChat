import ChatKit
import Foundation

// MARK: - Bootstrap (auto-login on app startup)

extension AppViewModel {
    /// Attempt a silent auto-login using the most-recently-used server profile.
    ///
    /// Called from `AppDelegate.applicationDidFinishLaunching` (Agent Y):
    /// ```swift
    /// Task { @MainActor in await appVM.bootstrap() }
    /// ```
    ///
    /// Flow:
    /// 1. Load the most-recently-used `ServerProfile`. If none exists, stay `.loggedOut`.
    /// 2. Inject the stored base URL and keychain token into the API client.
    /// 3. If no token is stored → stay `.loggedOut`.
    /// 4. Call `GET /api/auth/user`. On success → transition to `.loggedIn`, connect
    ///    the WebSocket, and load sessions.
    /// 5. On a 401 / expired token → wipe the keychain entry, stay `.loggedOut`.
    public func bootstrap() async {
        // Step 1: resolve the most-recently-used profile.
        guard let profile = serverProfileStore.mostRecent() else { return }
        currentServerProfile = profile

        // Step 2: configure the API client.
        await apiClient.setBaseURL(profile.url)

        // Step 3: check for a stored token.
        guard let token = keychain.token(for: profile.id), !token.isEmpty else { return }
        await apiClient.setToken(token)

        // Step 4: validate the token against the backend.
        do {
            let user = try await apiClient.currentUser()
            authState = .loggedIn(user: user)
            await connectAndLoad()
        } catch ChatKitError.notAuthenticated {
            // Step 5: token is stale — clean up.
            keychain.setToken(nil, for: profile.id)
            await apiClient.setToken(nil)
            // authState stays .loggedOut
        } catch {
            // Network/other error — don't wipe the token; user can retry manually.
        }
    }
}
