import ChatKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - App Color Palette
//
// WeChat-for-Mac aesthetic, with full light/dark support. Every token is a
// DYNAMIC color: it resolves to the light or dark value automatically based on
// the window's effective appearance (driven by AppSettings.appearanceMode →
// NSApp.appearance). Components must use these tokens — never hardcode
// Color.white / fixed hex — or they won't follow dark mode.

public enum AppColors {
    // MARK: Layout backgrounds

    /// Main window background / chat area
    public static let background = dyn(light: "#ededed", dark: "#1a1a1a")

    /// Left rail (dark sidebar) — already dark; deepen slightly in dark mode.
    public static let rail = dyn(light: "#2e2e2e", dark: "#1f1f1f")

    /// Middle sidebar background
    public static let sidebar = dyn(light: "#f4f4f4", dark: "#242424")

    /// Sidebar search bar background
    public static let sidebarSearch = dyn(light: "#ededed", dark: "#2c2c2c")

    /// Sidebar row divider
    public static let sidebarDivider = dyn(light: "#ececec", dark: "#2f2f2f")

    /// Selected conversation row background
    public static let rowSelected = dyn(light: "#d3d3d3", dark: "#3a3a3a")

    /// Hovered conversation row background
    public static let rowHovered = dyn(light: "#e8e8e8", dark: "#303030")

    // MARK: Chat bubbles

    /// User (outgoing) bubble — WeChat green (a touch deeper in dark mode)
    public static let userBubble = dyn(light: "#95ec69", dark: "#3eb575")

    /// Assistant (incoming) bubble
    public static let claudeBubble = dyn(light: "#ffffff", dark: "#2c2c2c")

    /// User bubble text — green bubble stays dark-on-green in both modes.
    public static let userBubbleText = dyn(light: "#1a1a1a", dark: "#0e1a10")

    /// Assistant bubble text
    public static let claudeBubbleText = dyn(light: "#1a1a1a", dark: "#e6e6e6")

    // MARK: Cards

    /// White card background (tool cards, file cards)
    public static let cardBackground = dyn(light: "#ffffff", dark: "#2c2c2c")

    /// Card icon container background
    public static let cardIconBackground = dyn(light: "#f6f6f6", dark: "#363636")

    /// Card border/divider
    public static let cardDivider = dyn(light: "#f0f0f0", dark: "#383838")

    // MARK: Composer

    public static let composerBackground = dyn(light: "#f7f7f7", dark: "#202020")

    /// Send button green — slightly different from user bubble
    public static let sendButton = dyn(light: "#07c160", dark: "#07c160")

    // MARK: System / UI

    /// System message pill background
    public static let systemMessage = dyn(light: "#d8d8d8", dark: "#3a3a3a")
    public static let systemMessageText = dyn(light: "#707070", dark: "#9a9a9a")

    /// Active rail icon background
    public static let railActiveBackground = dyn(light: "#3d3d3d", dark: "#333333")

    /// Rail icon tint (inactive)
    public static let railIcon = dyn(light: "#b0b0b0", dark: "#8a8a8a")

    /// Rail icon tint (active)
    public static let railIconActive = dyn(light: "#f0f0f0", dark: "#f0f0f0")

    // MARK: Badges

    public static let badge = dyn(light: "#fa5151", dark: "#f5564f")

    // MARK: Text

    public static let primaryText = dyn(light: "#1a1a1a", dark: "#e6e6e6")
    public static let secondaryText = dyn(light: "#888888", dark: "#8d8d8d")
    public static let tertiaryText = dyn(light: "#999999", dark: "#6f6f6f")
    public static let titleText = dyn(light: "#181818", dark: "#ededed")

    /// Link / action color (WeChat blue)
    public static let actionText = dyn(light: "#576b95", dark: "#7d97c4")

    // MARK: Code block

    public static let codeBackground = dyn(light: "#f6f6f6", dark: "#1e1e1e")

    // MARK: Detail panel

    public static let detailPanel = dyn(light: "#ffffff", dark: "#222222")
    public static let lineNumber = dyn(light: "#b0b0b0", dark: "#666666")

    // MARK: Borders

    public static let border = dyn(light: "#d8d8d8", dark: "#3a3a3a")
    public static let lightBorder = dyn(light: "#e0e0e0", dark: "#333333")
}

// MARK: - Dynamic (light/dark) color helper

#if canImport(AppKit)
/// Build a color that resolves to `light` or `dark` based on the current
/// NSAppearance. This is what makes the whole palette follow dark mode.
private func dyn(light: String, dark: String) -> Color {
    let lightNS = NSColor(hex: light)
    let darkNS = NSColor(hex: dark)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? darkNS : lightNS
    })
}
#else
private func dyn(light: String, dark: String) -> Color {
    Color(hex: light)
}
#endif

// MARK: - Hex Color Init

extension Color {
    /// Initialize from a CSS hex string like "#95ec69" or "95ec69".
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(h, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#if canImport(AppKit)
extension NSColor {
    /// Initialize from a CSS hex string like "#95ec69" or "95ec69".
    convenience init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(h, radix: 16) ?? 0
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat( value        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
#endif
