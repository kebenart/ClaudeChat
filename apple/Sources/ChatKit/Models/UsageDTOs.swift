import Foundation

// ============================================================================
// Usage / context occupancy DTOs (read-only displays)
//
// `GET /api/usage/claude-limits` → ClaudeUsageLimits (always present; the two
// window fields can be null when usage data isn't available yet).
// `GET /api/im/conversations/:id/context` → ConversationContext OR a literal
// JSON `null` (HTTP 200) when there's no data yet.
// ============================================================================

public struct UsageWindow: Sendable, Decodable {
    public let utilizationPct: Double
    public let resetsAt: String

    public init(utilizationPct: Double, resetsAt: String) {
        self.utilizationPct = utilizationPct
        self.resetsAt = resetsAt
    }
}

public struct ClaudeUsageLimits: Sendable, Decodable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    /// ms epoch when the server last fetched these limits from upstream.
    public let asOf: Double?

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, asOf: Double? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.asOf = asOf
    }
}

public struct ConversationContext: Sendable, Decodable {
    public let contextTokens: Int
    public let windowTokens: Int
    public let pct: Int

    public init(contextTokens: Int, windowTokens: Int, pct: Int) {
        self.contextTokens = contextTokens
        self.windowTokens = windowTokens
        self.pct = pct
    }
}
