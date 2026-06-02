import ChatKit
import SwiftUI

// MARK: - Font Size Enum

public enum AppFontSize: Int, CaseIterable, Sendable {
    case small = 12
    case medium = 13
    case large = 15
    case extraLarge = 17

    public var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }

    public var cgFloat: CGFloat { CGFloat(rawValue) }
}

// MARK: - AppFont Namespace

public enum AppFont {
    // MARK: Fixed point sizes (pixel-aligned, no Dynamic Type rounding)
    //
    // Dynamic Type semantic styles (.body / .callout / etc.) round to whichever
    // size the system has configured in Settings → Display → Text Size, which
    // means non-integer point sizes that don't pixel-align on Retina → blurry
    // text. We use fixed integer pt values everywhere. The chat-bubble body
    // is still user-adjustable through `message(size:)` below.

    public static let timestamp: Font      = .system(size: 10)
    public static let badge: Font          = .system(size: 9, weight: .medium)
    public static let sessionPreview: Font = .system(size: 11)
    public static let systemPill: Font     = .system(size: 11)
    public static let codeBlock: Font      = .system(size: 12, design: .monospaced)
    public static let lineNumber: Font     = .system(size: 12, design: .monospaced)

    // MARK: Dynamic (user-adjustable via Settings → 字体大小)

    /// Message bubble body text. Picks SF Pro at the user-chosen point size.
    public static func message(size: AppFontSize) -> Font {
        .system(size: size.cgFloat)
    }

    /// Session row title.
    public static func rowTitle(size: AppFontSize) -> Font {
        .system(size: min(size.cgFloat, 14))
    }
}

// MARK: - Environment Key

private struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: AppFontSize = .medium
}

extension EnvironmentValues {
    public var chatFontSize: AppFontSize {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
}
