import { useMemo, useState } from 'react';
import { ChevronDown, ChevronRight, Layers, MessageSquare, MessageSquarePlus, RefreshCw, Search, X } from 'lucide-react';

import type { Project, ProjectSession } from '../../types/app';
import type { WireConversation } from '../../services/im/protocol';

import WeChatSessionRow, { type WeChatSessionRowData } from './WeChatSessionRow';
import { useSessionMeta } from './useSessionMeta';

// MARK: - WeChatSidebar
//
// Chats tab equivalent of `Sources/ChatKit/UI/Sidebar/SidebarView.swift` —
// search header on top, scroll list below. Pinned rows sort above the rest;
// within each group, rows are sorted by lastActivity desc.
//
// Pin / mute / note state is stored client-side in localStorage keyed by
// session id (the existing data layer has no native fields for these), shared
// with the chat header menu via the `useSessionMeta` hook. The parent can
// intercept via the optional callbacks.

function pickActivity(session: ProjectSession): string | number | Date | null {
  // Existing data layer uses several shapes; prefer the most recent.
  const candidates = [session.lastActivity, session.updated_at, session.created_at, session.createdAt];
  for (const value of candidates) {
    if (value !== undefined && value !== null && value !== '') {
      return value as string | number | Date;
    }
  }
  return null;
}

function pickDisplayName(session: ProjectSession): string {
  // Prefer the user-visible fields the existing UI already shows.
  const fromSummary = typeof session.summary === 'string' ? session.summary.trim() : '';
  if (fromSummary) {
    return fromSummary;
  }
  const fromTitle = typeof session.title === 'string' ? session.title.trim() : '';
  if (fromTitle) {
    return fromTitle;
  }
  const fromName = typeof session.name === 'string' ? session.name.trim() : '';
  if (fromName) {
    return fromName;
  }
  return session.id.length > 8 ? `${session.id.slice(0, 8)}…` : session.id;
}

// Conversations are retained for 3 days (mirrors the server IM_RETENTION_DAYS).
// Pinned or currently-live sessions are kept regardless of age, matching the
// server's "active sessions never pruned" rule.
const RETENTION_MS = 3 * 24 * 60 * 60 * 1000;

function withinRetention(row: FlatRow, cutoff: number): boolean {
  if (row.isPinned || row.isOnline) return true;
  if (row.timestamp === null) return true; // unknown age — don't hide
  return row.timestamp >= cutoff;
}

function sortRows(rows: FlatRow[]): FlatRow[] {
  return [...rows].sort((a, b) => {
    if (a.isPinned !== b.isPinned) {
      return a.isPinned ? -1 : 1;
    }
    const ta = a.timestamp ?? 0;
    const tb = b.timestamp ?? 0;
    return tb - ta;
  });
}

interface FlatRow extends WeChatSessionRowData {
  timestamp: number | null;
  projectPath: string;
}

interface Props {
  projects: Project[];
  selectedSessionId?: string | null;
  onSelectSession: (sessionId: string, projectId: string) => void;
  onNewSession: () => void;
  /** User-triggered full re-sync (mirrors macOS refresh button / iOS pull-to-refresh). */
  onRefresh?: () => void | Promise<void>;
  onTogglePin?: (sessionId: string) => void;
  onToggleMute?: (sessionId: string) => void;
  onMarkRead?: (sessionId: string) => void;
  onRename?: (sessionId: string, newName: string) => void;
  onDelete?: (sessionId: string) => void;
  /** Lowercase substring filter; parent can pass `''` to disable. */
  initialSearch?: string;
  /** Per-session unread counts (overrides anything on `session.unreadCount`).
   * Counted by the parent from background `complete` WS frames. */
  unreadBySession?: Record<string, number>;
  /** IM hub conversations — source of the last-message preview + accurate
   * last-activity time, and the 3-day-retained set. */
  imConversations?: WireConversation[];
  /** Sessions Claude is actively running (green online dot). */
  liveSessionIds?: Set<string>;
}

export default function WeChatSidebar({
  projects,
  selectedSessionId,
  onSelectSession,
  onNewSession,
  onRefresh,
  onTogglePin,
  onToggleMute,
  onMarkRead,
  onRename,
  onDelete,
  initialSearch = '',
  unreadBySession,
  imConversations,
  liveSessionIds,
}: Props) {
  const [search, setSearch] = useState(initialSearch);
  const [foldedExpanded, setFoldedExpanded] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const handleRefresh = async () => {
    if (!onRefresh || isRefreshing) return;
    setIsRefreshing(true);
    try {
      await onRefresh();
    } finally {
      setIsRefreshing(false);
    }
  };
  const {
    pinned, muted, notes,
    togglePin: togglePinMeta, toggleMute: toggleMuteMeta, toggleFold, isFolded,
    isDeleted, deleteSession,
    isPathBlacklisted, toggleBlacklist, setNote,
  } = useSessionMeta(imConversations ?? []);

  const imMap = useMemo(
    () => new Map((imConversations ?? []).map((c) => [c.id, c])),
    [imConversations],
  );

  const rows = useMemo<FlatRow[]>(() => {
    const flat: FlatRow[] = [];
    for (const project of projects) {
      const projectDisplayName = project.displayName ?? project.fullPath ?? '';
      for (const session of project.sessions ?? []) {
        const imConv = imMap.get(session.id);
        const rawName = notes[session.id]?.trim() || pickDisplayName(session);
        // Prefer the IM hub's last-activity time (accurate + retention-aligned).
        const fallbackActivity = pickActivity(session);
        const fallbackTs =
          fallbackActivity instanceof Date
            ? fallbackActivity.getTime()
            : typeof fallbackActivity === 'number'
              ? fallbackActivity
              : typeof fallbackActivity === 'string'
                ? new Date(fallbackActivity).getTime() || null
                : null;
        const timestamp = imConv?.lastActivityAt ?? fallbackTs;
        const activity = imConv?.lastActivityAt ?? fallbackActivity;
        const isOnline = liveSessionIds?.has(session.id) ?? false;
        flat.push({
          id: session.id,
          projectId: project.projectId,
          projectPath: project.fullPath ?? project.path ?? '',
          displayName: rawName,
          searchHaystack: `${rawName} ${projectDisplayName}`.toLowerCase(),
          // Last message under the name; IM preview wins over the (usually empty)
          // projects-data preview.
          preview:
            imConv?.lastMessagePreview?.trim() ||
            (typeof session.preview === 'string' ? session.preview : undefined),
          // Always surface the last-message preview under the name; the green
          // dot (isOnline) conveys live status instead of a typing line.
          isTyping: false,
          isOnline,
          unreadCount:
            // Live counter from the parent wins; fall back to whatever the
            // server data carries (today = nothing for the WeChat flow).
            typeof unreadBySession?.[session.id] === 'number' && unreadBySession[session.id] > 0
              ? unreadBySession[session.id]
              : typeof session.unreadCount === 'number' && Number.isFinite(session.unreadCount)
              ? session.unreadCount
              : 0,
          lastActivity: activity,
          isPinned: pinned.has(session.id),
          isMuted: muted.has(session.id),
          timestamp: Number.isFinite(timestamp ?? NaN) ? (timestamp as number) : null,
        });
      }
    }
    // Dedupe by session id — the same session can surface under more than one
    // project entry after a silent projects refresh, which would render the
    // conversation twice. Keep the most-recently-active copy.
    const byId = new Map<string, FlatRow>();
    for (const row of flat) {
      const existing = byId.get(row.id);
      if (!existing || (row.timestamp ?? 0) > (existing.timestamp ?? 0)) {
        byId.set(row.id, row);
      }
    }
    const cutoff = Date.now() - RETENTION_MS;
    return sortRows([...byId.values()].filter((row) => withinRetention(row, cutoff)));
  }, [projects, notes, pinned, muted, unreadBySession, imMap, liveSessionIds]);

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase();
    if (!needle) {
      return rows;
    }
    return rows.filter((row) => row.searchHaystack?.includes(needle));
  }, [rows, search]);

  // Blacklisted project paths + soft-deleted conversations are hidden entirely.
  const notBlacklisted = useMemo(
    () => filtered.filter((r) => !isPathBlacklisted(r.projectPath) && !isDeleted(r.id)),
    [filtered, isPathBlacklisted, isDeleted],
  );
  // WeChat "折叠的聊天": folded rows collapse under a single expandable header.
  const mainRows = useMemo(() => notBlacklisted.filter((r) => !isFolded(r.id)), [notBlacklisted, isFolded]);
  const foldedRows = useMemo(() => notBlacklisted.filter((r) => isFolded(r.id)), [notBlacklisted, isFolded]);

  const togglePin = (sessionId: string) => {
    togglePinMeta(sessionId);
    onTogglePin?.(sessionId);
  };

  const toggleMute = (sessionId: string) => {
    toggleMuteMeta(sessionId);
    onToggleMute?.(sessionId);
  };

  const renameSession = (sessionId: string, newName: string) => {
    setNote(sessionId, newName);
    onRename?.(sessionId, newName);
  };

  // WeChat-style delete: server-synced (hidden on every client; resurrected on a
  // new inbound message). Also fire the optional parent callback for any local
  // cleanup (e.g. dropping out of the open chat).
  const deleteSessionRow = (sessionId: string) => {
    deleteSession(sessionId);
    onDelete?.(sessionId);
  };

  return (
    <div className="flex h-full w-full flex-col bg-[var(--wc-bg-sidebar)]">
      {/* Header: search input + new-session button */}
      <div className="flex items-center gap-2 border-b border-[var(--wc-border)] bg-[var(--wc-bg-header)] px-2.5 py-2">
        <div className="flex flex-1 items-center gap-1.5 rounded-[5px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] px-2 py-1">
          <Search className="h-3 w-3 shrink-0 text-[var(--wc-text-secondary)]" />
          <input
            type="text"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="搜索"
            className="min-w-0 flex-1 bg-transparent text-[12px] text-[var(--wc-text-primary)] outline-none placeholder:text-[var(--wc-text-secondary)]"
            autoCorrect="off"
            spellCheck={false}
          />
          {search && (
            <button
              type="button"
              onClick={() => setSearch('')}
              className="shrink-0 text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
              aria-label="清除搜索"
            >
              <X className="h-3 w-3" />
            </button>
          )}
        </div>
        {onRefresh && (
          <button
            type="button"
            onClick={handleRefresh}
            disabled={isRefreshing}
            title="刷新"
            aria-label="刷新"
            className="flex h-7 w-7 items-center justify-center rounded-[5px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] text-[var(--wc-text-secondary)] transition-colors hover:bg-[var(--wc-item-hover)] hover:text-[var(--wc-accent)] disabled:opacity-60"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${isRefreshing ? 'animate-spin' : ''}`} />
          </button>
        )}
        <button
          type="button"
          onClick={onNewSession}
          title="新建会话"
          aria-label="新建会话"
          className="flex h-7 w-7 items-center justify-center rounded-[5px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] text-[var(--wc-text-secondary)] transition-colors hover:bg-[var(--wc-item-hover)] hover:text-[var(--wc-accent)]"
        >
          <MessageSquarePlus className="h-3.5 w-3.5" />
        </button>
      </div>

      {/* Scrolling list */}
      <div className="flex-1 overflow-y-auto overscroll-contain">
        {mainRows.length === 0 && foldedRows.length === 0 ? (
          <div className="flex flex-col items-center gap-2 px-6 pt-12 text-center">
            {search ? (
              <Search className="h-8 w-8 text-zinc-300 dark:text-zinc-600" />
            ) : (
              <MessageSquare className="h-8 w-8 text-zinc-300 dark:text-zinc-600" />
            )}
            <p className="text-[13px] text-zinc-500 dark:text-zinc-400">
              {search ? '无搜索结果' : '暂无会话'}
            </p>
          </div>
        ) : (
          <div>
            {/* 折叠的聊天 group */}
            {foldedRows.length > 0 && (
              <div>
                <button
                  type="button"
                  onClick={() => setFoldedExpanded((v) => !v)}
                  className="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-[var(--wc-item-hover)]"
                >
                  <Layers className="h-3.5 w-3.5 text-[var(--wc-text-secondary)]" />
                  <span className="text-[13px] text-[var(--wc-text-primary)]">折叠的聊天</span>
                  <span className="text-[11px] text-[var(--wc-text-secondary)]">{foldedRows.length}</span>
                  <span className="ml-auto text-[var(--wc-text-secondary)]">
                    {foldedExpanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" />}
                  </span>
                </button>
                {foldedExpanded &&
                  foldedRows.map((row) => (
                    <div key={row.id} className="bg-[var(--wc-bg-search)]/40">
                      <WeChatSessionRow
                        row={row}
                        isSelected={selectedSessionId === row.id}
                        onSelect={onSelectSession}
                        onTogglePin={togglePin}
                        onToggleMute={toggleMute}
                        onToggleFold={toggleFold}
                        isFolded
                        onBlacklist={() => toggleBlacklist(row.projectPath)}
                        onMarkRead={onMarkRead}
                        onRename={renameSession}
                        onDelete={deleteSession}
                      />
                    </div>
                  ))}
                <div className="h-px bg-[var(--wc-border)]" />
              </div>
            )}
            {mainRows.map((row, index) => (
              <div key={row.id}>
                <WeChatSessionRow
                  row={row}
                  isSelected={selectedSessionId === row.id}
                  onSelect={onSelectSession}
                  onTogglePin={togglePin}
                  onToggleMute={toggleMute}
                  onToggleFold={toggleFold}
                  onBlacklist={() => toggleBlacklist(row.projectPath)}
                  onMarkRead={onMarkRead}
                  onRename={renameSession}
                  onDelete={deleteSession}
                />
                {index < mainRows.length - 1 && (
                  <div className="ml-[60px] h-px bg-[var(--wc-border)]" />
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
