import ChatKit
import SwiftUI
import Foundation

// MARK: - SessionListViewModel

/// Derives sidebar rows from storage and manages search state.
@Observable
@MainActor
public final class SessionListViewModel {
    // MARK: Published state

    public var rows: [SessionRowData] = []
    public var allSessions: [SessionRowData] = []      // includes hidden
    public var searchResults: SearchResults? = nil     // non-nil when searching
    public var searchText: String = ""
    public var isSearching: Bool = false

    // MARK: Client-side meta (fold) — derived from the server IM hub

    /// Folded session ids (WeChat "折叠的聊天"). Now sourced from the IM hub
    /// (im_conversations.is_folded) instead of local UserDefaults so it syncs
    /// across devices. Rebuilt on every `refresh()` from `storage.imConversations()`;
    /// AppViewModel owns the writes (`vm.setFolded`).
    public private(set) var foldedIds: Set<String> = []

    public func isFolded(_ id: String) -> Bool { foldedIds.contains(id) }

    // MARK: Private

    private let storage: any StorageProtocol

    public init(storage: some StorageProtocol) {
        self.storage = storage
    }

    /// Helper: a path is blacklisted if it equals, or nests under, a listed path.
    private func isPathBlacklisted(_ path: String?, in blacklist: Set<String>) -> Bool {
        guard let p = path, !p.isEmpty else { return false }
        return blacklist.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    // MARK: - Loading

    /// Refresh visible rows + search results from the visible sessions list.
    /// `unreadCounts` is kept for back-compat but `SessionInfo.unreadCount`
    /// is the authoritative source now.
    /// Conversations are retained for 3 days (mirrors server IM_RETENTION_DAYS).
    /// Pinned or currently-active sessions are kept regardless of age.
    private static let retention: TimeInterval = 3 * 24 * 60 * 60

    private static func withinRetention(_ s: SessionInfo, now: Date) -> Bool {
        if s.isPinned || s.isActive == true { return true }
        guard let ts = s.lastActivityAt else { return true } // unknown age — keep
        return now.timeIntervalSince(ts) <= retention
    }

    private static func withinRetentionMs(_ ms: Int, now: Date) -> Bool {
        guard ms > 0 else { return true }
        let secs = ms > 1_000_000_000_000 ? Double(ms) / 1000.0 : Double(ms)
        return now.timeIntervalSince(Date(timeIntervalSince1970: secs)) <= retention
    }

    /// Adapt an IM-hub conversation to the `SessionInfo` shape `SessionRowView`
    /// reads, so the row UI is unchanged while the data source becomes the hub.
    private func sessionInfo(from c: ImConversationDTO, unread: Int, live: Bool) -> SessionInfo {
        let ms = c.lastActivityAt
        let secs = ms > 1_000_000_000_000 ? Double(ms) / 1000.0 : Double(ms)
        return SessionInfo(
            id: c.id,
            projectPath: c.contactId ?? "",
            projectDisplayName: c.contactId.map { ($0 as NSString).lastPathComponent },
            title: c.title,
            lastActivityAt: ms > 0 ? Date(timeIntervalSince1970: secs) : nil,
            isActive: live,
            messageCount: nil,
            note: c.note,
            isPinned: c.isPinned,
            unreadCount: unread,
            latestMessagePreview: c.lastMessagePreview,
            isMuted: c.isMuted)
    }

    /// IM-hub-driven refresh (Stage 2): build the sidebar straight from
    /// ImConversationDTO — the same source iOS/web use — filtering deleted /
    /// blacklisted / out-of-retention and deriving fold. `rows` includes folded
    /// conversations; SidebarView splits them via `isFolded`.
    public func refresh(conversations: [ImConversationDTO],
                        unreadCounts: [String: Int],
                        blacklistedPaths: Set<String> = [],
                        liveSessionIds: Set<String> = []) async {
        foldedIds = Set(conversations.filter { $0.isFolded }.map { $0.id })
        let now = Date()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        func makeRow(_ c: ImConversationDTO) -> SessionRowData {
            let n = unreadCounts[c.id] ?? 0
            return SessionRowData(session: sessionInfo(from: c, unread: n, live: liveSessionIds.contains(c.id)),
                                  unread: n)
        }

        let visible = conversations
            .filter { !$0.isDeleted }
            .filter { !isPathBlacklisted($0.contactId, in: blacklistedPaths) }

        if q.isEmpty {
            rows = visible.filter { c in
                c.isPinned
                    || liveSessionIds.contains(c.id)
                    || (unreadCounts[c.id] ?? 0) > 0
                    || Self.withinRetentionMs(c.lastActivityAt, now: now)
            }.map(makeRow)
            isSearching = false
            searchResults = nil
        } else {
            rows = visible.filter {
                ($0.title ?? "").lowercased().contains(q)
                    || ($0.note ?? "").lowercased().contains(q)
                    || ($0.lastMessagePreview ?? "").lowercased().contains(q)
            }.map(makeRow)
            isSearching = true
            searchResults = nil
        }
    }

    public func refresh(sessions: [SessionInfo],
                        unreadCounts: [String: Int] = [:],
                        blacklistedPaths: Set<String> = []) async {
        // Overlay server-synced IM-hub state (pin/mute/note/fold) onto each
        // session so all three platforms show the same thing. Fold has no local
        // SessionRecord column, so it's derived here from the hub.
        let imConvs = await storage.imConversations()
        let imById = Dictionary(imConvs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        foldedIds = Set(imConvs.filter { $0.isFolded }.map { $0.id })
        // Server-synced soft delete: hide conversations the hub marks deleted.
        let deletedIds = Set(imConvs.filter { $0.isDeleted }.map { $0.id })

        func merged(_ s: SessionInfo) -> SessionInfo {
            guard let c = imById[s.id] else { return s }
            return SessionInfo(
                id: s.id, projectPath: s.projectPath, projectDisplayName: s.projectDisplayName,
                title: s.title, lastActivityAt: s.lastActivityAt, isActive: s.isActive,
                messageCount: s.messageCount,
                note: c.note ?? s.note, isPinned: c.isPinned,
                unreadCount: s.unreadCount, latestMessagePreview: s.latestMessagePreview,
                isMuted: c.isMuted)
        }

        if searchText.isEmpty {
            let now = Date()
            rows = sessions
                .filter { !deletedIds.contains($0.id) }
                .filter { Self.withinRetention($0, now: now) }
                .filter { !isPathBlacklisted($0.projectPath, in: blacklistedPaths) }
                .map { session in
                    let n = max(session.unreadCount, unreadCounts[session.id] ?? 0)
                    return SessionRowData(session: merged(session), unread: n)
                }
            isSearching = false
            searchResults = nil
        } else {
            let results = await storage.search(searchText)
            let matching = results.matchingSessions
            rows = matching.map { session in
                let n = max(session.unreadCount, unreadCounts[session.id] ?? 0)
                return SessionRowData(session: merged(session), unread: n)
            }
            isSearching = true
            searchResults = results
        }
    }

    /// Refresh the Contacts tab from the IM hub (Stage 6). Groups every
    /// conversation by project; deleted ones show dimmed (isHidden) like before.
    public func refreshAll(conversations: [ImConversationDTO], liveSessionIds: Set<String> = []) async {
        allSessions = conversations.map { c in
            SessionRowData(session: sessionInfo(from: c, unread: 0, live: liveSessionIds.contains(c.id)),
                           unread: 0, isHidden: c.isDeleted)
        }
    }

    public func clearSearch() {
        searchText = ""
        isSearching = false
        searchResults = nil
    }
}

// MARK: - SessionRowData

public struct SessionRowData: Identifiable, Sendable {
    public var id: String { session.id }
    public let session: SessionInfo
    public let unread: Int
    public let isHidden: Bool

    /// Badge display mode — always show the actual unread number (WeChat-style),
    /// not a bare dot, so the count is visible on the conversation row.
    public var badgeMode: BadgeMode {
        if unread > 0 { return .count(unread) }
        return .none
    }

    public init(session: SessionInfo, unread: Int, isHidden: Bool = false) {
        self.session = session
        self.unread = unread
        self.isHidden = isHidden
    }
}

public enum BadgeMode: Sendable {
    case none
    case dot
    case count(Int)
}
