import SwiftUI
import UIKit

// MARK: - WeChat palette (iOS)
//
// Mirrors the web --wc-* tokens (src/index.css). Light/dark resolved at runtime
// via UIColor trait closures so bubbles match WeChat on both appearances.

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
    static func dynamic(light: Int, dark: Int) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) }
    }
}

enum WC {
    /// Outgoing (me) bubble — WeChat green.
    static let bubbleOut = Color(uiColor: .dynamic(light: 0x95EC69, dark: 0x3EB575))
    static let bubbleOutText = Color(uiColor: .dynamic(light: 0x0D1B07, dark: 0xFFFFFF))
    /// Incoming (Claude) bubble — white / dark gray.
    static let bubbleIn = Color(uiColor: .dynamic(light: 0xFFFFFF, dark: 0x2C2C2C))
    static let bubbleInText = Color(uiColor: .dynamic(light: 0x181818, dark: 0xE7E7E7))
    /// Chat scroll background.
    static let chatBg = Color(uiColor: .dynamic(light: 0xEDEDED, dark: 0x191919))
    /// WeChat brand green (buttons, accents).
    static let accent = Color(uiColor: UIColor(rgb: 0x07C160))
}
