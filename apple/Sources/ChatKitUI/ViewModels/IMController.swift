import ChatKit
import Foundation

// MARK: - IMController
//
// Wires the ChatKit IM core (ImSyncEngine) into the macOS app.
// Owns:
//   - ImSyncEngine for fold /sync responses and im:* frames into Storage
//   - published unreadByConversation keyed by conversationId (== session id)
//
// Lifecycle:
//   1. Call start(apiClient:) once after login to run the initial paged /sync.
//   2. Route every ServerEvent from the socket through applyFrame(_:).
//   3. Call markRead(conversationId:lastSeq:) when a session is opened.
//   4. Call stop() on logout so the sync loop is cancelled.

@Observable
@MainActor
public final class IMController {
    // MARK: Published

    /// Keyed by conversationId (same as session id). Driven by ImSyncEngine.computeUnread().
    public var unreadByConversation: [String: Int] = [:]

    /// The IM-hub conversation list, sorted (pinned first, then most-recent).
    /// This is the source of truth the migrated macOS sidebar reads — populated
    /// on every sync/frame, exactly like iOS's IOSAppModel.conversations.
    public var conversations: [ImConversationDTO] = []

    /// Bumped after every sync/frame fold so observers (the sidebar) can
    /// re-derive overlay state (pin/mute/note/fold) that arrived from another
    /// device but did not change any unread count.
    public var syncRevision: Int = 0

    // MARK: Private

    private let engine: ImSyncEngine
    private let storage: Storage
    private var syncTask: Task<Void, Never>?
    /// Debounce handle for the per-frame list/unread refresh — coalesces a burst
    /// of im:* frames (a streaming reply emits many) into one refresh.
    private var refreshTask: Task<Void, Never>?
    private static let refreshDebounceNs: UInt64 = 250_000_000  // 250 ms

    /// Highest seq we've already marked-read + POSTed per conversation. Guards
    /// against re-POSTing the same read receipt: ImChatView's onChange(syncRevision)
    /// calls markRead on every sync frame, which otherwise spammed the server with
    /// a POST /im/read + a full refreshUnread on each frame of a streaming reply.
    private var lastMarkedSeq: [String: Int] = [:]

    /// How many recent messages per conversation to pull on a cold start. A few
    /// conversations hold 1000+ messages; capping keeps the first sync small
    /// (mirrors iOS — the full backfill into SwiftData pegged CPU/heat). Older
    /// history is lazy-loaded via the transcript view on demand.
    private static let coldStartRecent = 30

    /// Conversations the user deleted, kept hidden until the server confirms
    /// is_deleted=1 — PERSISTED so the delete survives an app restart even if its
    /// /state POST was lost, and re-asserted to the server on launch (mirrors iOS).
    public private(set) var locallyDeletedIds: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(locallyDeletedIds), forKey: Self.locallyDeletedKey) }
    }
    private static let locallyDeletedKey = "mac_locally_deleted"

    // MARK: - Init

    public init(storage: Storage) {
        self.storage = storage
        self.engine = ImSyncEngine(storage: storage)
        if let saved = UserDefaults.standard.array(forKey: Self.locallyDeletedKey) as? [String] {
            self.locallyDeletedIds = Set(saved)
        }
    }

    /// Record/clear a local delete guard (called from AppViewModel.deleteConversation).
    /// The row stays hidden via refreshUnread's override until the server confirms
    /// the delete, then it's dropped.
    public func markLocallyDeleted(_ id: String, _ deleted: Bool) {
        if deleted { locallyDeletedIds.insert(id) } else { locallyDeletedIds.remove(id) }
    }

    // MARK: - Lifecycle

    /// Run the initial paged /sync then keep unread up-to-date.
    /// Call after a successful login / connectAndLoad.
    public func start(apiClient: some APIClientProtocol) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runInitialSync(apiClient: apiClient)
        }
    }

    /// Cancel any running sync task. Call on logout.
    public func stop() {
        syncTask?.cancel()
        syncTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        unreadByConversation = [:]
        lastMarkedSeq = [:]
    }

    /// Coalesced list/unread refresh: collapses a burst of im:* frames into a
    /// single refreshUnread after a short quiet period. The sync paths and
    /// markRead still refresh directly (they are not per-frame).
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshDebounceNs)
            guard let self, !Task.isCancelled else { return }
            await self.refreshUnread()
        }
    }

    // MARK: - Frame routing

    /// Route an incoming ServerEvent. Call from AppViewModel.handleServerEvent for every event.
    /// - `.imMessage` / `.imRead` are folded into storage; unread is recomputed.
    /// - `.imPoke(since:)` triggers a re-sync from the given cursor.
    public func applyFrame(_ event: ServerEvent, apiClient: some APIClientProtocol) {
        switch event {
        case .imMessage, .imRead:
            Task { [weak self] in
                guard let self else { return }
                // Fold the frame into storage immediately (the open chat reads it),
                // but coalesce the list/unread refresh — a streaming reply emits a
                // burst of frames and re-sorting + recomputing unread on each one
                // re-rendered the whole sidebar per frame.
                await self.engine.applyFrame(event)
                self.scheduleRefresh()
            }
        case let .imPoke(since):
            Task { [weak self] in
                guard let self else { return }
                await self.runIncrementalSync(apiClient: apiClient, since: since)
            }
        default:
            break
        }
    }

    // MARK: - Read state query

    /// The highest read-cursor seq across ALL devices for a conversation — the
    /// same value the unread badge derives from. A reply whose seq is ≤ this has
    /// already been read somewhere, so the badge wouldn't show. Used to keep
    /// notifications in lock-step with the red dot.
    public func maxReadSeq(conversationId: String) async -> Int {
        await storage.imReadCursors()
            .filter { $0.conversationId == conversationId }
            .map(\.lastReadSeq)
            .max() ?? 0
    }

    // MARK: - Mark read

    /// Mark a conversation as read locally and broadcast to the server.
    /// Call when a session is opened/focused.
    public func markRead(conversationId: String, apiClient: some APIClientProtocol) {
        Task { [weak self] in
            guard let self else { return }
            // Find the lastSeq for this conversation.
            let conversations = await self.storage.imConversations()
            guard let conv = conversations.first(where: { $0.id == conversationId }) else {
                // No IM data yet for this conversation — nothing to mark.
                return
            }
            let seq = conv.lastSeq
            // Nothing new since we last marked this conversation read → skip the
            // storage write, the network POST, AND the full refreshUnread. This is
            // what stops the per-frame read-receipt storm during a streaming reply.
            if let prev = self.lastMarkedSeq[conversationId], prev >= seq { return }
            self.lastMarkedSeq[conversationId] = seq
            let deviceId = DeviceIdentity.current()
            // Update local read cursor.
            await self.storage.setImReadCursor(
                conversationId: conversationId,
                deviceId: deviceId,
                lastReadSeq: seq
            )
            // Broadcast to server (best-effort).
            try? await apiClient.postImRead(
                conversationId: conversationId,
                deviceId: deviceId,
                lastReadSeq: seq
            )
            // Recompute unread so the badge disappears immediately.
            await self.refreshUnread()
        }
    }

    // MARK: - Private helpers

    /// Initial sync. On a cold start (empty local store) pull only recent-N per
    /// conversation and let the server jump our cursor to its max rev — mirrors
    /// iOS, and avoids streaming the entire message history into SwiftData (the
    /// dead `recent` cap meant macOS backfilled everything on every first login).
    /// On a warm start, page incrementally until !hasMore or the cursor stalls.
    private func runInitialSync(apiClient: some APIClientProtocol) async {
        let startCursor = await storage.imSyncCursor()

        if startCursor == 0 {
            guard !Task.isCancelled else { return }
            do {
                let resp = try await apiClient.fetchImSync(since: 0, recent: Self.coldStartRecent)
                await engine.applySync(resp)
            } catch {
                NSLog("[IMController] cold-start sync error: \(error)")
            }
            await baselineReadCursors()
            await refreshUnread()
            await reassertPendingDeletes(apiClient: apiClient)
            return
        }

        var cursor = startCursor
        repeat {
            guard !Task.isCancelled else { return }
            do {
                let resp = try await apiClient.fetchImSync(since: cursor)
                await engine.applySync(resp)
                let newCursor = await storage.imSyncCursor()
                if !resp.hasMore || newCursor == cursor { break }
                cursor = newCursor
            } catch {
                NSLog("[IMController] initial sync error: \(error)")
                break
            }
        } while true
        await baselineReadCursors()
        await refreshUnread()
        await reassertPendingDeletes(apiClient: apiClient)
    }

    /// Establish an "everything so far is read" baseline: any conversation that
    /// has no read cursor for this device gets one at its current lastSeq. This
    /// stops backfilled history (which the user never opened on this device)
    /// from counting as a huge unread total. Only newly-arriving messages (which
    /// push lastSeq above the cursor) then count as unread.
    private func baselineReadCursors() async {
        let deviceId = DeviceIdentity.current()
        let existing = Set(await storage.imReadCursors()
            .filter { $0.deviceId == deviceId }
            .map { $0.conversationId })
        for conv in await storage.imConversations() where !existing.contains(conv.id) {
            await storage.setImReadCursor(conversationId: conv.id, deviceId: deviceId, lastReadSeq: conv.lastSeq)
        }
    }

    /// Re-POST any locally-pending deletes the server hasn't recorded yet — a
    /// /state POST can be lost (network / app quit), so make the intent durable on
    /// launch. refreshUnread has already dropped server-confirmed ids, so whatever
    /// remains in locallyDeletedIds is genuinely unconfirmed.
    private func reassertPendingDeletes(apiClient: some APIClientProtocol) async {
        for id in locallyDeletedIds {
            try? await apiClient.postImState(conversationId: id, isPinned: nil, isMuted: nil,
                                             isFolded: nil, isDeleted: true, note: nil)
        }
    }

    /// Incremental sync from a given cursor (triggered by im:poke).
    private func runIncrementalSync(apiClient: some APIClientProtocol, since: Int) async {
        var cursor = since
        repeat {
            guard !Task.isCancelled else { return }
            do {
                let resp = try await apiClient.fetchImSync(since: cursor)
                await engine.applySync(resp)
                let newCursor = await storage.imSyncCursor()
                if !resp.hasMore || newCursor == cursor { break }
                cursor = newCursor
            } catch {
                NSLog("[IMController] incremental sync error: \(error)")
                break
            }
        } while true
        await refreshUnread()
    }

    /// Recompute the conversation list + unread from storage and publish on the
    /// MainActor. Sorted pinned-first then most-recent, with a stable id tiebreak
    /// (mirrors iOS so the list never jiggles under a re-sort).
    private func refreshUnread() async {
        var convs = await storage.imConversations()
        // Durable-delete guard: drop ids the server has now confirmed deleted, then
        // force-hide the rest. A lost /state POST leaves the server at is_deleted=0,
        // but the user deleted it — keep it hidden until the re-assert lands.
        if !locallyDeletedIds.isEmpty {
            locallyDeletedIds.subtract(convs.filter { $0.isDeleted }.map { $0.id })
            if !locallyDeletedIds.isEmpty {
                convs = convs.map { locallyDeletedIds.contains($0.id) ? $0.with(isDeleted: true) : $0 }
            }
        }
        convs.sort {
            let a = ($0.isPinned ? 1 : 0, $0.lastActivityAt)
            let b = ($1.isPinned ? 1 : 0, $1.lastActivityAt)
            if a != b { return a > b }
            return $0.id < $1.id
        }
        let counts = await engine.computeUnread()
        let nonZero = counts.filter { $0.value > 0 }
        conversations = convs
        unreadByConversation = nonZero
        syncRevision += 1
    }

    /// Re-publish the conversation list from storage now — used after a local
    /// optimistic edit so the sidebar reflects pin/mute/fold/note/delete
    /// immediately instead of only after a tab switch.
    public func refreshNow() async { await refreshUnread() }

    /// Manual refresh (sidebar refresh button): re-pull /sync from the cursor.
    public func resync(apiClient: some APIClientProtocol) async {
        let cursor = await storage.imSyncCursor()
        await runIncrementalSync(apiClient: apiClient, since: cursor)
    }

    // MARK: - Reads for the IM-driven UI

    /// Messages for one conversation (the migrated chat reads these instead of
    /// provider ChatMessages).
    public func messages(_ conversationId: String) async -> [ImMessageDTO] {
        await storage.imMessages(conversationId: conversationId)
    }
}
