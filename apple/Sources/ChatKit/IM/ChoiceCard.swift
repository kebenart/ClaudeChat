import Foundation

// MARK: - ChoiceCard
//
// An interactive "选择卡" (WeChat 红包-style card) that arrives as a normal IM
// message with `kind == "choice"`. Its `content` is a JSON string we decode into
// this model. Two flavors:
//   • AskUserQuestion — one or more questions, each with selectable options.
//   • ExitPlanMode    — a plan blob the user 同意 / 拒绝.
// When answered, the SAME message re-syncs with `answered == true` plus a
// human-readable `answer` summary; the card then renders as a resolved chip.

public struct ChoiceCard: Sendable, Decodable, Hashable, Identifiable {
    /// Identity = the request id, so SwiftUI can present the poll via
    /// `.sheet(item:)` from a stable parent (not the volatile message row).
    public var id: String { requestId }
    public let requestId: String
    public let toolName: String
    public let questions: [ChoiceQuestion]?
    public let plan: String?
    public let answered: Bool?
    public let answer: String?

    public init(requestId: String, toolName: String,
                questions: [ChoiceQuestion]? = nil, plan: String? = nil,
                answered: Bool? = nil, answer: String? = nil) {
        self.requestId = requestId
        self.toolName = toolName
        self.questions = questions
        self.plan = plan
        self.answered = answered
        self.answer = answer
    }

    /// True when the user has already responded — render a dimmed resolved card.
    public var isAnswered: Bool { answered ?? false }

    /// True for the AskUserQuestion (poll) flavor.
    public var isAskUserQuestion: Bool { toolName == "AskUserQuestion" }
    /// True for the ExitPlanMode (同意/拒绝) flavor.
    public var isExitPlanMode: Bool { toolName == "ExitPlanMode" }

    /// Decode a choice message's `content` JSON string. Returns nil when the
    /// string isn't valid choice JSON (so callers can fall back gracefully).
    public static func parse(_ content: String) -> ChoiceCard? {
        guard let data = content.data(using: .utf8) else { return nil }
        guard let card = try? JSONDecoder().decode(ChoiceCard.self, from: data) else { return nil }
        // A valid choice always carries a requestId + toolName.
        guard !card.requestId.isEmpty, !card.toolName.isEmpty else { return nil }
        return card
    }
}

public struct ChoiceQuestion: Sendable, Decodable, Hashable {
    public let question: String
    public let header: String?
    public let multiSelect: Bool?
    public let options: [ChoiceOption]

    public init(question: String, header: String? = nil,
                multiSelect: Bool? = nil, options: [ChoiceOption]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    public var allowsMultiple: Bool { multiSelect ?? false }
}

public struct ChoiceOption: Sendable, Decodable, Hashable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}
