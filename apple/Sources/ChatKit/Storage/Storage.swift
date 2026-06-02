import Foundation
import SwiftData

// ============================================================================
// Storage — actor that owns a ModelContext and satisfies StorageProtocol.
//
// All @Model objects live on this actor. Every public method either takes or
// returns Sendable value types (DTOs) so callers never hold @Model references
// across actor boundaries.
//
// Protocol extension added to StorageProtocol:
//   func setHasPendingApproval(sessionId: String, _ value: Bool) async
//   — needed by EventReducer to mark/clear the pending-approval badge.
// ============================================================================

public actor Storage: StorageProtocol {

    private let container: ModelContainer
    // Module-internal so IM extensions (Sources/ChatKit/IM/ImStorage.swift) can
    // reuse the same actor-isolated context.
    let context: ModelContext

    // MARK: - Init

    public init(container: ModelContainer) {
        self.container = container
        // ModelContext is not Sendable; create it on the actor's executor.
        self.context = ModelContext(container)
        self.context.autosaveEnabled = true
    }

    // MARK: - Private helpers

    /// Fetch a single `SessionRecord` by id, or nil if absent.
    private func fetchSession(_ id: String) throws -> SessionRecord? {
        let predicate = #Predicate<SessionRecord> { $0.id == id }
        let descriptor = FetchDescriptor<SessionRecord>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    /// Fetch a single `MessageRecord` by id, or nil if absent.
    private func fetchMessage(_ id: String) throws -> MessageRecord? {
        let predicate = #Predicate<MessageRecord> { $0.id == id }
        let descriptor = FetchDescriptor<MessageRecord>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    // MARK: - Sessions

    public func upsertSession(_ session: SessionInfo) async {
        do {
            if let existing = try fetchSession(session.id) {
                existing.projectPath = session.projectPath
                existing.projectDisplayName = session.projectDisplayName
                if let title = session.title { existing.title = title }
                if let at = session.lastActivityAt { existing.lastActivityAt = at }
                // note / isPinned are client-side. Only overwrite if caller passed
                // non-default values; otherwise preserve the existing user input.
                if let note = session.note { existing.note = note }
                if session.isPinned { existing.isPinned = true }
            } else {
                let record = SessionRecord(
                    id: session.id,
                    projectPath: session.projectPath,
                    projectDisplayName: session.projectDisplayName,
                    title: session.title,
                    lastActivityAt: session.lastActivityAt ?? Date(),
                    note: session.note,
                    isPinned: session.isPinned
                )
                context.insert(record)
            }
            try context.save()
        } catch {
            // Logging only — we never surface SwiftData errors to callers per protocol.
            print("[Storage] upsertSession failed: \(error)")
        }
    }

    public func upsertSessions(_ sessions: [SessionInfo]) async {
        for s in sessions { await upsertSession(s) }
    }

    public func setHidden(sessionId: String, hidden: Bool) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.isHidden = hidden
            try context.save()
        } catch {
            print("[Storage] setHidden failed: \(error)")
        }
    }

    public func incrementUnread(sessionId: String) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.unreadCount += 1
            try context.save()
        } catch {
            print("[Storage] incrementUnread failed: \(error)")
        }
    }

    public func clearUnread(sessionId: String) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.unreadCount = 0
            try context.save()
        } catch {
            print("[Storage] clearUnread failed: \(error)")
        }
    }

    public func listSessions(includingHidden: Bool) async -> [SessionInfo] {
        do {
            // SwiftData SortDescriptor on Bool keypaths requires NSObject which
            // @Model types are not. So fetch sorted by lastActivityAt, then
            // re-sort in Swift to put pinned sessions first.
            let sortBy: [SortDescriptor<SessionRecord>] = [
                SortDescriptor(\.lastActivityAt, order: .reverse),
            ]
            let descriptor: FetchDescriptor<SessionRecord>
            if includingHidden {
                descriptor = FetchDescriptor<SessionRecord>(sortBy: sortBy)
            } else {
                let predicate = #Predicate<SessionRecord> { !$0.isHidden }
                descriptor = FetchDescriptor<SessionRecord>(predicate: predicate, sortBy: sortBy)
            }
            let records = try context.fetch(descriptor)
            // Stable partition: pinned first, otherwise preserve activity order.
            let pinned = records.filter { $0.isPinned }
            let rest = records.filter { !$0.isPinned }
            return (pinned + rest).map { $0.toDTO() }
        } catch {
            print("[Storage] listSessions failed: \(error)")
            return []
        }
    }

    public func sessionExists(_ id: String) async -> Bool {
        do {
            return try fetchSession(id) != nil
        } catch {
            return false
        }
    }

    // MARK: - Messages

    public func upsertMessage(_ message: ChatMessage) async {
        do {
            if let existing = try fetchMessage(message.id) {
                existing.content = message.content
                existing.roleRaw = message.role.rawValue
                existing.isStreaming = message.isStreaming
                existing.createdAt = message.createdAt
                existing.sendStatus = message.sendStatus
                existing.sendError = message.sendError
                if let tool = message.toolUse {
                    existing.toolName = tool.name
                    existing.toolInput = tool.input
                    existing.toolOutput = tool.output
                    existing.toolApprovalState = tool.approvalState
                    existing.toolRequestId = tool.requestId
                }
            } else {
                let record = MessageRecord(
                    id: message.id,
                    sessionId: message.sessionId,
                    role: message.role,
                    content: message.content,
                    toolName: message.toolUse?.name,
                    toolInput: message.toolUse?.input,
                    toolOutput: message.toolUse?.output,
                    toolApprovalState: message.toolUse?.approvalState,
                    toolRequestId: message.toolUse?.requestId,
                    createdAt: message.createdAt,
                    isStreaming: message.isStreaming,
                    sendStatus: message.sendStatus,
                    sendError: message.sendError
                )
                context.insert(record)
                // Link to parent session so the cascade delete relationship is correct.
                if let session = try fetchSession(message.sessionId) {
                    session.messages.append(record)
                    session.lastActivityAt = max(session.lastActivityAt, message.createdAt)
                }
            }
            // Denormalise the latest preview onto the session so the sidebar can
            // show "你: hi" or "Claude: 好的, ..." without a per-row query.
            if let session = try fetchSession(message.sessionId) {
                session.latestMessagePreview = makePreview(role: message.role, content: message.content)
            }
            try context.save()
        } catch {
            print("[Storage] upsertMessage failed: \(error)")
        }
    }

    private func makePreview(role: MessageRole, content: String) -> String {
        let prefix: String
        switch role {
        case .user:      prefix = "你: "
        case .assistant: prefix = ""
        case .tool:      prefix = "[工具] "
        case .system:    prefix = "[系统] "
        }
        let body = content.replacingOccurrences(of: "\n", with: " ")
        return String((prefix + body).prefix(80))
    }

    public func appendStreamDelta(messageId: String, sessionId: String, delta: String) async {
        do {
            if let existing = try fetchMessage(messageId) {
                existing.content += delta
                existing.isStreaming = true
                // Touch session's lastActivityAt + refresh preview.
                if let session = try fetchSession(sessionId) {
                    session.lastActivityAt = Date()
                    session.latestMessagePreview = makePreview(role: existing.role, content: existing.content)
                }
            } else {
                // First chunk: derive id per contract rule in StorageModels.swift.
                // The messageId passed here is the one from the backend assistantText event,
                // so we use it directly as it's already canonical.
                let record = MessageRecord(
                    id: messageId,
                    sessionId: sessionId,
                    role: .assistant,
                    content: delta,
                    createdAt: Date(),
                    isStreaming: true
                )
                context.insert(record)
                if let session = try fetchSession(sessionId) {
                    session.messages.append(record)
                    session.lastActivityAt = Date()
                    session.latestMessagePreview = makePreview(role: .assistant, content: delta)
                }
            }
            try context.save()
        } catch {
            print("[Storage] appendStreamDelta failed: \(error)")
        }
    }

    public func finalizeStreaming(messageId: String) async {
        do {
            guard let record = try fetchMessage(messageId) else { return }
            record.isStreaming = false
            record.createdAt = Date()
            try context.save()
        } catch {
            print("[Storage] finalizeStreaming failed: \(error)")
        }
    }

    public func finalizeStreaming(sessionId: String) async {
        do {
            let predicate = #Predicate<MessageRecord> { $0.sessionId == sessionId && $0.isStreaming }
            let streaming = try context.fetch(FetchDescriptor<MessageRecord>(predicate: predicate))
            guard !streaming.isEmpty else { return }
            for record in streaming { record.isStreaming = false }
            try context.save()
        } catch {
            print("[Storage] finalizeStreaming(sessionId:) failed: \(error)")
        }
    }

    public func messages(sessionId: String) async -> [ChatMessage] {
        do {
            let predicate = #Predicate<MessageRecord> { $0.sessionId == sessionId }
            let descriptor = FetchDescriptor<MessageRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            return try context.fetch(descriptor).map { $0.toDTO() }
        } catch {
            print("[Storage] messages failed: \(error)")
            return []
        }
    }

    public func latestMessage(sessionId: String) async -> ChatMessage? {
        do {
            let predicate = #Predicate<MessageRecord> { $0.sessionId == sessionId }
            var descriptor = FetchDescriptor<MessageRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.toDTO()
        } catch {
            print("[Storage] latestMessage failed: \(error)")
            return nil
        }
    }

    // MARK: - Search

    public func search(_ query: String) async -> SearchResults {
        guard !query.isEmpty else { return SearchResults() }
        let lowered = query.lowercased()
        do {
            // Session title search
            let allSessions = try context.fetch(FetchDescriptor<SessionRecord>())
            let matchingSessions = allSessions
                .filter { ($0.title ?? "").lowercased().contains(lowered) }
                .map { $0.toDTO() }

            // Message content search
            let allMessages = try context.fetch(FetchDescriptor<MessageRecord>())
            let matchingMessages = allMessages
                .filter { $0.content.lowercased().contains(lowered) }
                .map { (sessionId: $0.sessionId, message: $0.toDTO()) }

            return SearchResults(
                matchingSessions: matchingSessions,
                matchingMessages: matchingMessages
            )
        } catch {
            print("[Storage] search failed: \(error)")
            return SearchResults()
        }
    }

    // MARK: - Bookkeeping

    public func reset() async {
        do {
            try context.delete(model: MessageRecord.self)
            try context.delete(model: SessionRecord.self)
            try context.save()
        } catch {
            print("[Storage] reset failed: \(error)")
        }
    }

    // MARK: - Protocol extension (added to StorageProtocol in Protocols.swift)

    /// Mark or clear the hasPendingApproval badge on a session.
    /// Called by EventReducer on `permissionRequest` / `permissionCancelled`.
    public func setHasPendingApproval(sessionId: String, _ value: Bool) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.hasPendingApproval = value
            record.lastActivityAt = Date()
            try context.save()
        } catch {
            print("[Storage] setHasPendingApproval failed: \(error)")
        }
    }

    public func setNote(sessionId: String, _ note: String?) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            // Empty string treated as nil so the displayName helper falls back to title.
            if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                record.note = n
            } else {
                record.note = nil
            }
            try context.save()
        } catch {
            print("[Storage] setNote failed: \(error)")
        }
    }

    public func setPinned(sessionId: String, _ pinned: Bool) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.isPinned = pinned
            try context.save()
        } catch {
            print("[Storage] setPinned failed: \(error)")
        }
    }

    public func setMuted(sessionId: String, _ muted: Bool) async {
        do {
            guard let record = try fetchSession(sessionId) else { return }
            record.isMuted = muted
            try context.save()
        } catch {
            print("[Storage] setMuted failed: \(error)")
        }
    }

    /// Update the SendStatus on a user message. No-op if the message is missing.
    public func setSendStatus(messageId: String, _ status: SendStatus) async {
        do {
            guard let record = try fetchMessage(messageId) else { return }
            record.sendStatus = status
            // Clear any stale error message when the status moves away from failed.
            if status != .failed { record.sendError = nil }
            try context.save()
        } catch {
            print("[Storage] setSendStatus failed: \(error)")
        }
    }

    public func setSendFailure(messageId: String, reason: String) async {
        do {
            guard let record = try fetchMessage(messageId) else { return }
            record.sendStatus = .failed
            record.sendError = reason
            try context.save()
        } catch {
            print("[Storage] setSendFailure failed: \(error)")
        }
    }

    /// Bulk-update SendStatus for every user-role message in a session.
    /// Only flips `.sending` / `.sent` → `.delivered`. Does NOT touch
    /// `.failed`: those represent real prior errors the user needs to see, and
    /// silently rewriting them was masking genuine "send failed" bubbles every
    /// time a *later* message succeeded.
    public func markUserMessagesDelivered(sessionId: String) async {
        do {
            let predicate = #Predicate<MessageRecord> {
                $0.sessionId == sessionId && $0.roleRaw == "user"
            }
            let records = try context.fetch(FetchDescriptor<MessageRecord>(predicate: predicate))
            for r in records {
                let s = r.sendStatus
                if s == .sent || s == .sending {
                    r.sendStatus = .delivered
                    r.sendError = nil
                }
            }
            try context.save()
        } catch {
            print("[Storage] markUserMessagesDelivered failed: \(error)")
        }
    }
}

