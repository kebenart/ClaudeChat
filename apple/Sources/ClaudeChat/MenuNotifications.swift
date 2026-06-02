import Foundation
import ChatKit
import ChatKitUI

// MARK: - Menu Notification Names

public extension Notification.Name {
    /// Posted when the user chooses File > New Chat.
    static let newChatRequested = Notification.Name("ClaudeChat.newChatRequested")

    /// Posted when the user picks a font size from View > Font Size.
    /// userInfo: ["size": AppFontSize]
    static let fontSizeChanged = Notification.Name("ClaudeChat.fontSizeChanged")

    /// Posted when the user picks a numbered session from Window > Switch Session.
    /// userInfo: ["index": Int]  (0-based)
    static let switchSessionRequested = Notification.Name("ClaudeChat.switchSessionRequested")

    /// Posted when the user chooses App Menu > Preferences.
    static let openPreferencesRequested = Notification.Name("ClaudeChat.openPreferencesRequested")
}
