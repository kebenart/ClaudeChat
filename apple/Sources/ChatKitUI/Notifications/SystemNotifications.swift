import ChatKit
@preconcurrency import UserNotifications
import AppKit

// MARK: - SystemNotifications

/// Utility namespace for macOS local (UNUserNotification) alerts.
/// All methods are @MainActor to allow safe access to AppViewModel state
/// from the call sites in handleServerEvent.
@MainActor
public enum SystemNotifications {

    /// `UNUserNotificationCenter.current()` does not just fail when notifications
    /// are unavailable — it **aborts the whole process** (SIGABRT via a
    /// `dispatch_once` terminate) that we cannot catch in Swift. It does this
    /// when there is no app bundle (e.g. `swift run`) AND, more subtly, when
    /// Launch Services cannot resolve our bundle id back to a registered app at
    /// our own path (a stale copy elsewhere, or the app launched from an
    /// unregistered location before `lsregister` has seen it).
    ///
    /// So gate every entry point on TWO checks, both of which are abort-free:
    ///   1. a real bundle id exists, and
    ///   2. Launch Services resolves that id to *this* bundle's URL.
    /// If either fails we skip notifications (best-effort) rather than crash.
    nonisolated static var isAvailable: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        guard let registered = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        return registered.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // MARK: - Permission

    /// Strong-held delegate so foreground banners are shown (see below).
    nonisolated(unsafe) private static let presentationDelegate = ForegroundBannerDelegate()

    /// Request UNUserNotification authorization once at startup.
    /// Safe to call repeatedly — idempotent at the OS level.
    public static func requestPermissionIfNeeded() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        // Without a delegate that opts in, macOS suppresses the banner whenever
        // our app is frontmost. Install one so replies notify even in-app.
        center.delegate = presentationDelegate
        let settings = await center.notificationSettings() as UNNotificationSettings
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Silently ignore — notifications are best-effort.
            NSLog("[SystemNotifications] requestAuthorization failed: \(error)")
        }
    }

    // MARK: - Generic notify

    /// Schedule a local notification that fires immediately (trigger = nil).
    ///
    /// CRITICAL — must be `nonisolated`. The `add(_:withCompletionHandler:)`
    /// callback runs on UN's internal serial queue (`com.apple.usernotifications…`).
    /// Under Swift 6 strict concurrency, a MainActor-isolated closure firing
    /// on that queue triggers `dispatch_assert_queue_fail` / SIGTRAP. We saw
    /// the crash come in via UNUserNotificationServiceConnection.call-out →
    /// closure #1 in notify → swift_task_isCurrentExecutorImpl. The body of
    /// this function does not touch MainActor state, so making it nonisolated
    /// (and the completion `@Sendable`) eliminates the precondition.
    nonisolated public static func notify(title: String, body: String, sound: Bool = true) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil          // nil → deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error {
                NSLog("[SystemNotifications] add request failed: \(error)")
            }
        }
    }

    // MARK: - Specific helpers

    /// Notify the user that Claude replied in a background session.
    nonisolated public static func notifyClaudeReplied(sessionTitle: String, preview: String) {
        notify(
            title: "Claude replied in \"\(sessionTitle)\"",
            body: preview.isEmpty ? "New message" : preview,
            sound: true
        )
    }

    /// Notify the user that an error occurred in a session.
    nonisolated public static func notifyClaudeError(sessionTitle: String, message: String) {
        notify(
            title: "Error in \"\(sessionTitle)\"",
            body: message.isEmpty ? "An error occurred" : message,
            sound: false
        )
    }

    /// Notify the user that a tool is waiting for manual approval.
    nonisolated public static func notifyToolApprovalNeeded(sessionTitle: String, toolName: String) {
        notify(
            title: "Approval needed in \"\(sessionTitle)\"",
            body: "\"\(toolName)\" is requesting permission to run",
            sound: true
        )
    }
}

/// Allows notification banners to appear even when our app is the frontmost
/// app (macOS otherwise routes them straight to Notification Center silently).
private final class ForegroundBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
