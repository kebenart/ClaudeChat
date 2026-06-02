import Foundation

extension String {
    /// Whitespace/newline-trimmed copy — used to match optimistic echoes
    /// against the server's possibly-normalized copy.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension StringProtocol {
    /// Nicknames render at most 10 characters; anything longer is truncated with
    /// an ellipsis. Shared by the chat list, contacts, and chat headers so the
    /// rule is consistent everywhere a display name appears.
    var clampedNickname: String {
        count > 10 ? prefix(10) + "…" : String(self)
    }
}
