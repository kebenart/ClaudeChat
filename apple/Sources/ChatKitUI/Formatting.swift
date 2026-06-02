import Foundation

extension StringProtocol {
    /// Nicknames render at most 10 characters; longer names are truncated with
    /// an ellipsis. Applied at display sites (sidebar rows, chat header) so the
    /// rule matches the iOS and web clients.
    var clampedNickname: String {
        count > 10 ? prefix(10) + "…" : String(self)
    }
}
