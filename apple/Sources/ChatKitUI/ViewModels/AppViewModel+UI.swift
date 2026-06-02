import ChatKit
import Foundation

// MARK: - AppViewModel+UI
//
// UI-layer helpers that Agent Z owns. Do NOT add these to AppViewModel.swift.

extension AppViewModel {

    // MARK: - Profile switching

    /// Switch to a different server profile:
    /// 1. Updates currentServerProfile and configures the API client.
    /// 2. Loads the stored token for the profile.
    /// 3. If a token exists, verifies it by calling currentUser().
    ///    - On success → .loggedIn
    ///    - On failure → .loggedOut
    /// 4. If no token → .loggedOut
    public func switchProfile(_ profile: ServerProfile) async {
        currentServerProfile = profile
        await apiClient.setBaseURL(profile.url)

        if let token = keychain.token(for: profile.id) {
            await apiClient.setToken(token)
            do {
                let user = try await apiClient.currentUser()
                authState = .loggedIn(user: user)
                await loadSessions()
            } catch {
                await apiClient.setToken(nil)
                authState = .loggedOut
            }
        } else {
            await apiClient.setToken(nil)
            authState = .loggedOut
        }
    }

    // MARK: - UI-local cleanup

    /// Clear UI-local caches. Call this after logout or before switching profile.
    /// Does NOT modify authState — call vm.logout() first if needed.
    public func cleanupUI() async {
        sessions = []
        currentSessionId = nil
        unreadCounts = [:]
    }

    // MARK: - Logout

    /// Calls logout() then clears all UI-local caches.
    /// The authState is set to .loggedOut by logout(); RootView will switch to LoginView.
    public func logoutAndCleanup() async {
        await logout()
        await cleanupUI()
    }

}
