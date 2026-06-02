import AppKit
import ChatKit
import SwiftUI

// MARK: - AppearanceMode

/// User's window appearance preference. `.system` follows the OS setting; the
/// other two force light/dark regardless of the system.
public enum AppearanceMode: Int, CaseIterable, Sendable {
    case system = 0
    case light = 1
    case dark = 2

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// The AppKit appearance to assign to `NSApp.appearance`. `nil` for `.system`
    /// means "don't override — inherit the OS appearance".
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - AppSettings

/// Global app-level preferences.
///
/// Stored as observable properties (so SwiftUI re-renders) and mirrored into
/// UserDefaults via `didSet` for persistence. The earlier `@AppStorage`-backed
/// design did not work with `@Observable`: marking the underlying storage
/// `@ObservationIgnored` (which `@AppStorage` requires to coexist) silently
/// disables change tracking, so the font-size picker never propagated.
@Observable
public final class AppSettings: @unchecked Sendable {

    private enum Key {
        static let chatFontSize = "chatFontSize"
        static let appearanceMode = "appearanceMode"
        static let autoApproveAll = "autoApproveAll"
        static let currentServerProfileId = "currentServerProfileId"
    }

    // MARK: Display

    public var chatFontSize: AppFontSize {
        didSet { UserDefaults.standard.set(chatFontSize.rawValue, forKey: Key.chatFontSize) }
    }

    /// Light / dark / follow-system window appearance. Persisted, and applied to
    /// `NSApp.appearance` via `applyAppearance()` (called on change + at launch).
    public var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
            applyAppearance()
        }
    }

    /// Push the current `appearanceMode` onto the running NSApplication. Hops to
    /// the main actor (NSApp is main-actor isolated).
    public func applyAppearance() {
        let appearance = appearanceMode.nsAppearance
        Task { @MainActor in NSApplication.shared.appearance = appearance }
    }

    // MARK: Behavior

    public var autoApproveAll: Bool {
        didSet { UserDefaults.standard.set(autoApproveAll, forKey: Key.autoApproveAll) }
    }

    // MARK: Server

    public var currentServerProfileId: UUID? {
        didSet {
            UserDefaults.standard.set(currentServerProfileId?.uuidString ?? "", forKey: Key.currentServerProfileId)
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        let storedFontRaw = defaults.integer(forKey: Key.chatFontSize)
        self.chatFontSize = AppFontSize(rawValue: storedFontRaw == 0 ? AppFontSize.medium.rawValue : storedFontRaw) ?? .medium
        // rawValue 0 == .system, which is also the correct default when unset.
        self.appearanceMode = AppearanceMode(rawValue: defaults.integer(forKey: Key.appearanceMode)) ?? .system
        self.autoApproveAll = defaults.bool(forKey: Key.autoApproveAll)
        let profileStr = defaults.string(forKey: Key.currentServerProfileId) ?? ""
        self.currentServerProfileId = profileStr.isEmpty ? nil : UUID(uuidString: profileStr)
    }
}
