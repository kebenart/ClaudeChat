import ChatKit
import SwiftUI

// MARK: - ImChatViewModel
//
// macOS analog of the iOS ChatDetailView state: renders the IM hub's
// ImMessageDTO stream (filtered to text/result/error) for one conversation,
// with optimistic-echo reconciliation. Stage 3 of the macOS → IM-hub migration.

@Observable
@MainActor
public final class ImChatViewModel {
    /// Server messages worth showing as bubbles.
    public private(set) var messages: [ImMessageDTO] = []
    /// Locally-echoed user sends, shown instantly until the server echoes them.
    public private(set) var pending: [ImMessageDTO] = []

    private var confirmedPendingIds: Set<String> = []
    private var claimedServerIds: Set<String> = []
    /// Pending ids whose send threw — surfaced as a red "!" + tap-to-resend, and
    /// exempt from the 120s pending TTL until resent/confirmed.
    public private(set) var failedPendingIds: Set<String> = []

    /// Only bubble real chat turns — tool_use/thinking/tool_result/meta are noise.
    private static let bubbleKinds: Set<String> = ["text", "result", "error", "choice", "image"]

    // MARK: Display window (virtualization)
    //
    // A conversation can hold hundreds/thousands of messages. Rendering them all
    // in one LazyVStack still accumulates identity + layout for every row, so the
    // scroll bar grows huge and scrolling stalls. We instead keep only the most
    // recent `visibleWindow` messages in `displayed`; older ones load on demand
    // via `loadEarlier()` (a "加载更早的消息" button at the top). The full set
    // stays in `messages` — this is purely a render cap, no re-fetch.

    /// How many most-recent messages to show initially / grow by per "load more".
    private static let windowStep = 80
    /// Current cap on how many of `messages` are rendered (grows on loadEarlier).
    public private(set) var visibleWindow = windowStep

    /// True when there are older messages not yet in the window.
    public var hasEarlier: Bool { messages.count > visibleWindow }

    public init() {}

    /// Server messages (capped to the recent window) + optimistic ones the server
    /// hasn't echoed back yet.
    ///
    /// CRITICAL: `pending` is a single shared array on this (singleton) view model,
    /// but it must only contribute bubbles to the conversation it belongs to.
    /// Without the conversationId filter, an un-confirmed optimistic message (e.g.
    /// a send that never got reconciled) leaked into EVERY conversation's bubble
    /// list — showing the same bubble in all chats, and twice in its own (once as
    /// the server echo, once as the orphan pending).
    public var displayed: [ImMessageDTO] {
        let recent = messages.count > visibleWindow
            ? Array(messages.suffix(visibleWindow))
            : messages
        let livePending = pending.filter {
            !confirmedPendingIds.contains($0.id) && $0.conversationId == loadedConversationId
        }
        return recent + livePending
    }

    /// Grow the window to reveal an earlier page. Returns the id of the message
    /// that was at the top BEFORE growing, so the view can anchor scroll there
    /// (keeping the user's reading position instead of jumping).
    @discardableResult
    public func loadEarlier() -> String? {
        guard hasEarlier else { return nil }
        let anchorId = displayed.first?.id
        visibleWindow = min(messages.count, visibleWindow + Self.windowStep)
        return anchorId
    }

    /// Append an optimistic user bubble (called synchronously from the send tap).
    /// Returns its id so the caller can flag it failed / resend it.
    @discardableResult
    public func appendPending(_ text: String, conversationId: String) -> String {
        let id = "local-\(UUID().uuidString)"
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        pending.append(ImMessageDTO(
            id: id,
            conversationId: conversationId,
            seq: Int.max, role: "user", kind: "text",
            content: text, createdAt: nowMs, toolTrace: nil))
        return id
    }

    public func markFailed(_ id: String) { failedPendingIds.insert(id) }
    public func markSending(_ id: String) { failedPendingIds.remove(id) }
    public func isFailed(_ id: String) -> Bool { failedPendingIds.contains(id) }

    /// Reload from the IM hub and reconcile optimistic echoes (each server
    /// user-message confirms at most one pending — ported from iOS).
    /// The conversation `messages` currently holds — used to detect a switch so
    /// we can reset the display window back to the most-recent page.
    private var loadedConversationId: String?

    public func reload(_ conversationId: String, using controller: IMController?) async {
        guard let controller else { messages = []; return }
        // Switching conversations: collapse back to the recent window so we don't
        // carry a huge window (and its scroll cost) into the new chat.
        if conversationId != loadedConversationId {
            visibleWindow = Self.windowStep
            loadedConversationId = conversationId
        }
        let all = await controller.messages(conversationId)
        messages = all.filter { Self.bubbleKinds.contains($0.kind) }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let serverUserMsgs = messages.filter { $0.role == "user" }
        // Reconcile ONLY this conversation's pending against this conversation's
        // server echoes. `pending` is shared across all chats (singleton VM), so a
        // pending from another conversation must never be matched here.
        for p in pending.sorted(by: { $0.createdAt < $1.createdAt })
        where p.conversationId == conversationId && !confirmedPendingIds.contains(p.id) {
            if let match = serverUserMsgs.first(where: {
                !claimedServerIds.contains($0.id)
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    == p.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }) {
                claimedServerIds.insert(match.id)
                confirmedPendingIds.insert(p.id)
            }
        }
        // Drop pending that are confirmed, OR that aged out (120s) — but only for
        // THIS conversation, so we don't TTL-evict another chat's in-flight sends.
        // (The conversationId guard also means a stuck/failed orphan from a chat
        // you never reopen still ages out next time you open THAT chat.)
        pending.removeAll {
            confirmedPendingIds.contains($0.id)
            || ($0.conversationId == conversationId
                && (nowMs - $0.createdAt) > 120_000
                && !failedPendingIds.contains($0.id))
        }
        confirmedPendingIds = confirmedPendingIds.intersection(Set(pending.map(\.id)))
        claimedServerIds = claimedServerIds.intersection(Set(messages.map(\.id)))
        failedPendingIds = failedPendingIds.intersection(Set(pending.map(\.id)))
    }
}
