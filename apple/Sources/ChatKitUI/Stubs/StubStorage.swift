import ChatKit
import Foundation

// MARK: - StubStorage
// TODO: swap to SwiftData-backed storage on integration

public actor StubStorage: StorageProtocol {
    private var sessions: [String: SessionInfo] = [:]
    private var hiddenIds: Set<String> = []
    private var unread: [String: Int] = [:]
    private var messages: [String: [ChatMessage]] = [:]  // keyed by sessionId

    public init() {}

    // MARK: Sessions

    public func upsertSession(_ session: SessionInfo) async {
        sessions[session.id] = session
    }

    public func upsertSessions(_ incoming: [SessionInfo]) async {
        for s in incoming { sessions[s.id] = s }
    }

    public func setHidden(sessionId: String, hidden: Bool) async {
        if hidden { hiddenIds.insert(sessionId) }
        else { hiddenIds.remove(sessionId) }
    }

    public func incrementUnread(sessionId: String) async {
        unread[sessionId, default: 0] += 1
    }

    public func clearUnread(sessionId: String) async {
        unread[sessionId] = 0
    }

    public func listSessions(includingHidden: Bool) async -> [SessionInfo] {
        sessions.values
            .filter { includingHidden || !hiddenIds.contains($0.id) }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    public func sessionExists(_ id: String) async -> Bool {
        sessions[id] != nil
    }

    // MARK: Messages

    public func upsertMessage(_ message: ChatMessage) async {
        var list = messages[message.sessionId] ?? []
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
        } else {
            list.append(message)
        }
        messages[message.sessionId] = list
    }

    public func appendStreamDelta(messageId: String, sessionId: String, delta: String) async {
        var list = messages[sessionId] ?? []
        if let idx = list.firstIndex(where: { $0.id == messageId }) {
            var msg = list[idx]
            msg.content += delta
            list[idx] = msg
        } else {
            let msg = ChatMessage(id: messageId, sessionId: sessionId,
                                  role: .assistant, content: delta, isStreaming: true)
            list.append(msg)
        }
        messages[sessionId] = list
    }

    public func finalizeStreaming(messageId: String) async {
        // Mark the streaming message as done
        for (sid, var list) in messages {
            if let idx = list.firstIndex(where: { $0.id == messageId }) {
                var msg = list[idx]
                msg.isStreaming = false
                list[idx] = msg
                messages[sid] = list
                return
            }
        }
    }

    public func finalizeStreaming(sessionId: String) async {
        guard var list = messages[sessionId] else { return }
        for idx in list.indices where list[idx].isStreaming {
            list[idx].isStreaming = false
        }
        messages[sessionId] = list
    }

    public func messages(sessionId: String) async -> [ChatMessage] {
        (messages[sessionId] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    public func latestMessage(sessionId: String) async -> ChatMessage? {
        messages[sessionId]?.max(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: Search

    public func search(_ query: String) async -> SearchResults {
        let q = query.lowercased()
        let matchSessions = sessions.values.filter {
            ($0.title ?? "").lowercased().contains(q) ||
            $0.projectDisplayName?.lowercased().contains(q) == true
        }
        let matchMessages = messages.flatMap { (sid, msgs) in
            msgs.filter { $0.content.lowercased().contains(q) }
                .map { (sessionId: sid, message: $0) }
        }
        return SearchResults(
            matchingSessions: Array(matchSessions),
            matchingMessages: matchMessages
        )
    }

    // MARK: Bookkeeping

    public func reset() async {
        sessions = [:]
        hiddenIds = []
        unread = [:]
        messages = [:]
    }

    // MARK: Extended (Agent B protocol addition)

    public func setHasPendingApproval(sessionId: String, _ value: Bool) async {
        // Stub: no-op
    }

    public func setNote(sessionId: String, _ note: String?) async {
        // Stub: no-op
    }

    public func setPinned(sessionId: String, _ pinned: Bool) async {
        // Stub: no-op
    }

    public func setMuted(sessionId: String, _ muted: Bool) async {
        // Stub: no-op
    }

    public func setSendStatus(messageId: String, _ status: SendStatus) async {
        // Stub: no-op
    }

    public func setSendFailure(messageId: String, reason: String) async {
        // Stub: no-op
    }

    public func markUserMessagesDelivered(sessionId: String) async {
        // Stub: no-op
    }

    // MARK: - IM hub conversations (in-memory)

    private var imConvs: [String: ImConversationDTO] = [:]

    public func imConversations() async -> [ImConversationDTO] {
        Array(imConvs.values)
    }

    public func upsertImConversation(_ conversation: ImConversationDTO) async {
        imConvs[conversation.id] = conversation
    }
}
