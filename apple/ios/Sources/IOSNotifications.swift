import Foundation
import UserNotifications

/// Local notifications + app icon badge for AI replies. No remote APNs — the
/// app posts a local notification when a `complete`/`im:message` arrives while
/// the relevant chat isn't in the foreground.
public enum IOSNotifications {
    // All methods are `nonisolated` and use the async APIs so completion handlers
    // don't run as MainActor-isolated closures on UN's background queue — that
    // tripped a Swift 6 concurrency assertion and crashed right after the user
    // granted permission.
    nonisolated public static func requestAuthorization() {
        Task.detached {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    nonisolated public static func notifyAssistantReply(conversationTitle: String, preview: String, totalUnread: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Claude 在「\(conversationTitle)」中回复了"
        content.body = preview
        content.sound = .default
        content.badge = NSNumber(value: totalUnread)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task.detached { try? await UNUserNotificationCenter.current().add(req) }
    }

    nonisolated public static func setBadge(_ count: Int) {
        Task.detached { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
}
