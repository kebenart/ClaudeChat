import ChatKit
import SwiftUI

// MARK: - AvatarHashing

public enum AvatarHashing {
    /// 12-color palette matching the mockup's WeChat-style avatar colors.
    private static let palette: [Color] = [
        Color(hex: "#e15c5c"),  // red
        Color(hex: "#d97316"),  // orange
        Color(hex: "#ca8a04"),  // amber
        Color(hex: "#36a3a0"),  // teal
        Color(hex: "#22a86d"),  // green
        Color(hex: "#3b82f6"),  // blue
        Color(hex: "#5a8fc0"),  // steel blue
        Color(hex: "#6366f1"),  // indigo
        Color(hex: "#7a4fd6"),  // purple
        Color(hex: "#db2777"),  // pink
        Color(hex: "#7c6547"),  // brown
        Color(hex: "#64748b"),  // slate
    ]

    /// Deterministically pick one of the 12 palette colors for a given seed string.
    public static func color(for seed: String) -> Color {
        guard !seed.isEmpty else { return palette[0] }
        // Use a stable polynomial hash (not Swift's .hashValue which is non-deterministic)
        var hash: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            hash = (hash &* 31) &+ UInt64(scalar.value)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Deterministically map a seed to an index in [0, count) using the same
    /// stable polynomial hash. Used to pick a fixed gallery avatar per seed.
    public static func index(for seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard !seed.isEmpty else { return 0 }
        var hash: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            hash = (hash &* 31) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(count))
    }

    /// Returns the display text for an avatar: first CJK character, or first ASCII
    /// letter (uppercased), or "?" as fallback.
    public static func text(for title: String) -> String {
        guard !title.isEmpty else { return "?" }

        // First CJK unified ideograph
        for scalar in title.unicodeScalars {
            let v = scalar.value
            if (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Ext-A
            || (v >= 0x20000 && v <= 0x2A6DF)  // CJK Ext-B
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            {
                return String(scalar)
            }
        }

        // First ASCII letter uppercased
        for char in title where char.isLetter && char.isASCII {
            return String(char).uppercased()
        }

        return "?"
    }
}
