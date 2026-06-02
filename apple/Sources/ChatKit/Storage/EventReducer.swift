import Foundation

// ============================================================================
// EventReducer — consumes an AsyncStream<ServerEvent> and drives Storage
// mutations to keep the local DB in sync with the live backend.
//
// Design notes:
// - EventReducer is a regular (non-actor) class that calls the `Storage`
//   actor from within an async task. It is Sendable because all mutable state
//   is either immutable after init or guarded by the Storage actor.
// - `isSessionFocused` is a @Sendable closure so it can be called freely
//   inside the async stream loop without capturing anything non-Sendable.
//
// Missing ServerEvent cases that could be useful (proposed additions — do NOT
// edit Events.swift directly per the task rules; propose here for Agent A):
//   case sessionList([SessionInfo])     — populate sidebar from server snapshot
//   case sessionDeleted(sessionId: String) — hard-delete from local DB
// ============================================================================

public final class EventReducer: Sendable {

    private let storage: Storage
    /// Returns true when the user is actively viewing the given session's chat.
    /// Used to decide whether an incoming `complete` event should increment
    /// the unread badge.
    private let isSessionFocused: @Sendable (String) -> Bool

    public init(storage: Storage, isSessionFocused: @Sendable @escaping (String) -> Bool) {
        self.storage = storage
        self.isSessionFocused = isSessionFocused
    }

    /// Consume every event from `stream` and apply the appropriate mutations.
    /// This method runs until the stream ends (i.e. until the WebSocket closes
    /// or the caller cancels the task).
    public func consume(_ stream: AsyncStream<ServerEvent>) async {
        for await event in stream {
            await handle(event)
        }
    }

    // MARK: - Private dispatch

    private func handle(_ event: ServerEvent) async {
        switch event {

        // -----------------------------------------------------------------
        // session_created — create or upsert the SessionRecord.
        // We use the sessionId as a minimal SessionInfo; the full metadata
        // (projectPath, title) will be filled in by the APIClient later.
        // -----------------------------------------------------------------
        case let .sessionCreated(sessionId):
            let session = SessionInfo(
                id: sessionId,
                projectPath: "",          // filled in when projects are fetched
                lastActivityAt: Date()
            )
            await storage.upsertSession(session)

        // -----------------------------------------------------------------
        // assistantText — streaming delta or full text.
        // For isDelta==true we append; for isDelta==false we overwrite/upsert.
        // -----------------------------------------------------------------
        case let .assistantText(sessionId, messageId, text, isDelta):
            // Ensure the parent session exists
            if await !storage.sessionExists(sessionId) {
                await storage.upsertSession(
                    SessionInfo(id: sessionId, projectPath: "", lastActivityAt: Date())
                )
            }
            if isDelta {
                await storage.appendStreamDelta(
                    messageId: messageId,
                    sessionId: sessionId,
                    delta: text
                )
            } else {
                // Full replacement (e.g. re-hydration from the server).
                let msg = ChatMessage(
                    id: messageId,
                    sessionId: sessionId,
                    role: .assistant,
                    content: text,
                    createdAt: Date(),
                    isStreaming: false
                )
                await storage.upsertMessage(msg)
            }

        // -----------------------------------------------------------------
        // complete — finalise the streaming message; update unread if needed.
        // -----------------------------------------------------------------
        case let .complete(sessionId, _, _, _):
            // Finalise the last streaming message for this session (if any).
            // We look up the latest message and flip isStreaming.
            if let latest = await storage.latestMessage(sessionId: sessionId),
               latest.isStreaming {
                await storage.finalizeStreaming(messageId: latest.id)
            }
            // Increment unread only when the user is not looking at this session.
            if !isSessionFocused(sessionId) {
                await storage.incrementUnread(sessionId: sessionId)
            }

        // -----------------------------------------------------------------
        // toolUse — insert or upsert a tool MessageRecord.
        // messageId = toolUse's unique message id from the backend.
        // -----------------------------------------------------------------
        case let .toolUse(sessionId, messageId, name, input):
            if await !storage.sessionExists(sessionId) {
                await storage.upsertSession(
                    SessionInfo(id: sessionId, projectPath: "", lastActivityAt: Date())
                )
            }
            let msg = ChatMessage(
                id: messageId,
                sessionId: sessionId,
                role: .tool,
                content: "",
                toolUse: ToolInvocation(name: name, input: input),
                createdAt: Date(),
                isStreaming: false
            )
            await storage.upsertMessage(msg)

        // -----------------------------------------------------------------
        // toolResult — attach output to the matching tool MessageRecord.
        // toolUseId matches the messageId used when the toolUse was inserted.
        // -----------------------------------------------------------------
        case let .toolResult(sessionId, toolUseId, output, isError):
            let existing = await storage.latestMessage(sessionId: sessionId)
            // Try to find the message by toolUseId — if it already exists,
            // upsertMessage will update it; otherwise create a new one.
            // Derive a stable id: we use toolUseId as the record id since
            // backend tool-result frames reference the same id as tool-use.
            let resultContent = isError ? "[error] \(output)" : output
            if let msg = existing, msg.id == toolUseId {
                // Update in place via upsert
                var updated = msg
                let updatedTool = ToolInvocation(
                    name: updated.toolUse?.name ?? "",
                    input: updated.toolUse?.input ?? "",
                    output: resultContent,
                    approvalState: updated.toolUse?.approvalState,
                    requestId: updated.toolUse?.requestId,
                    requiresApproval: false
                )
                updated = ChatMessage(
                    id: updated.id,
                    sessionId: updated.sessionId,
                    role: updated.role,
                    content: updated.content,
                    toolUse: updatedTool,
                    createdAt: updated.createdAt,
                    isStreaming: false
                )
                await storage.upsertMessage(updated)
            } else {
                // No prior tool-use message found with that id; insert a result record.
                let msg = ChatMessage(
                    id: toolUseId,
                    sessionId: sessionId,
                    role: .tool,
                    content: resultContent,
                    toolUse: ToolInvocation(name: "tool", input: "", output: resultContent),
                    createdAt: Date(),
                    isStreaming: false
                )
                await storage.upsertMessage(msg)
            }

        // -----------------------------------------------------------------
        // permissionRequest — insert a pending tool approval MessageRecord
        // and mark the session badge.
        // -----------------------------------------------------------------
        case let .permissionRequest(sessionId, requestId, toolName, input, _):
            if await !storage.sessionExists(sessionId) {
                await storage.upsertSession(
                    SessionInfo(id: sessionId, projectPath: "", lastActivityAt: Date())
                )
            }
            // Derive a stable message id from the requestId (requestIds are
            // unique per permission request per the backend contract).
            let msgId = "perm-\(requestId)"
            let msg = ChatMessage(
                id: msgId,
                sessionId: sessionId,
                role: .tool,
                content: "",
                toolUse: ToolInvocation(
                    name: toolName,
                    input: input,
                    approvalState: .pending,
                    requestId: requestId,
                    requiresApproval: true
                ),
                createdAt: Date(),
                isStreaming: false
            )
            await storage.upsertMessage(msg)
            await storage.setHasPendingApproval(sessionId: sessionId, true)

        // -----------------------------------------------------------------
        // permissionCancelled — update the tool message to timedOut/cancelled.
        // -----------------------------------------------------------------
        case let .permissionCancelled(sessionId, requestId, reason):
            let msgId = "perm-\(requestId)"
            let newState: ApprovalState = (reason == "timeout") ? .timedOut : .cancelled
            // Read → mutate → write pattern via messages query.
            let msgs = await storage.messages(sessionId: sessionId)
            if let existing = msgs.first(where: { $0.id == msgId }),
               var tool = existing.toolUse {
                tool = ToolInvocation(
                    name: tool.name,
                    input: tool.input,
                    output: tool.output,
                    approvalState: newState,
                    requestId: tool.requestId,
                    requiresApproval: false
                )
                let updated = ChatMessage(
                    id: existing.id,
                    sessionId: existing.sessionId,
                    role: existing.role,
                    content: existing.content,
                    toolUse: tool,
                    createdAt: existing.createdAt,
                    isStreaming: false
                )
                await storage.upsertMessage(updated)
            }
            await storage.setHasPendingApproval(sessionId: sessionId, false)

        // -----------------------------------------------------------------
        // status — log; optionally insert a system message for visibility.
        // -----------------------------------------------------------------
        case let .status(sessionId, text, _):
            print("[EventReducer] status [\(sessionId)]: \(text)")
            // System messages derived from status frames use a timestamp-based id.
            // We do NOT insert system messages by default to avoid noise; callers
            // can subclass EventReducer and override handle() if they want them.

        // -----------------------------------------------------------------
        // error — log; optionally insert a system error message.
        // -----------------------------------------------------------------
        case let .error(sessionId, message):
            let sid = sessionId ?? "unknown"
            print("[EventReducer] error [\(sid)]: \(message)")

        // -----------------------------------------------------------------
        // sessionStatus — no storage mutation needed; UI observes liveness
        // via the ChatSocket directly.
        // -----------------------------------------------------------------
        case .sessionStatus:
            break

        // -----------------------------------------------------------------
        // IM hub frames — folded into the IM store by ImSyncEngine, not here.
        // -----------------------------------------------------------------
        case .imMessage, .imRead, .imPoke:
            break

        // -----------------------------------------------------------------
        // imStatus — transient turn progress; no DB write. App models hold it.
        // -----------------------------------------------------------------
        case .imStatus:
            break

        // -----------------------------------------------------------------
        // connection — synthesized lifecycle event; surfaced to app models,
        // not persisted here.
        // -----------------------------------------------------------------
        case .connection:
            break

        // -----------------------------------------------------------------
        // raw — unknown frame; log for diagnostics.
        // -----------------------------------------------------------------
        case let .raw(kind, type_, _):
            print("[EventReducer] unhandled raw event kind=\(kind ?? "nil") type=\(type_ ?? "nil")")
        }
    }
}
