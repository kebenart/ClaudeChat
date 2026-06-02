import Foundation

// MARK: - Auth State
//
// Core type: consumed by AuthCoordinator (network layer) and the UI layer.
// Lives in the iOS-safe core so both macOS UI and iOS app can use it.

public enum AuthState: Sendable {
    /// Initial state before `bootstrapAuth()` has finished probing the server
    /// for DEV_AUTH_BYPASS / running keychain restore. Showing LoginView during
    /// this window would flash incorrectly.
    case bootstrapping
    case loggedOut
    /// The user passed username+password but TOTP is required. `totpToken` is the
    /// short-lived JWT issued by the server; client must echo it back along with
    /// the 6-digit code via `POST /api/auth/login/totp`.
    case totpRequired(totpToken: String)
    /// The user just logged in for the first time and has not yet enrolled TOTP.
    /// Holds the authenticated user so the setup screen can proceed with auth.
    case totpSetupRequired(user: User)
    case loggedIn(user: User)
}
