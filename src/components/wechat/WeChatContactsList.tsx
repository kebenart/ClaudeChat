import { useMemo, useState } from 'react';
import { Ban, ChevronRight, Pin, UserPlus, Users } from 'lucide-react';

import type { Project, ProjectSession } from '../../types/app';
import type { WireConversation } from '../../services/im/protocol';
import { clampNickname } from '../../utils/nickname';

import WeChatAvatar from './WeChatAvatar';
import { useSessionMeta } from './useSessionMeta';

// Conversations are retained for 3 days (mirrors server IM_RETENTION_DAYS).
const RETENTION_MS = 3 * 24 * 60 * 60 * 1000;

// MARK: - WeChatContactsList
//
// Contacts tab equivalent of `SidebarView.swift::contactsList` + `CompactContactRow`.
// Sessions are grouped by project display name; group headers are uppercase,
// muted, with a count next to them. Each row is a compact 32px avatar + name
// + optional pin marker.
//
// The pin state is read from the same localStorage key WeChatSidebar writes to
// (`wechat:pinned-sessions`) so toggling pin in one view is reflected in both.

const PINNED_KEY = 'wechat:pinned-sessions';

function readPinned(): Set<string> {
  try {
    const raw = localStorage.getItem(PINNED_KEY);
    if (!raw) {
      return new Set();
    }
    const parsed = JSON.parse(raw) as unknown;
    if (Array.isArray(parsed)) {
      return new Set(parsed.filter((item): item is string => typeof item === 'string'));
    }
  } catch {
    // ignore
  }
  return new Set();
}

function pickDisplayName(session: ProjectSession): string {
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

/** Robust last-activity timestamp (ms) for a session, preferring the IM hub. */
function sessionTimestamp(session: ProjectSession, imLastActivityAt?: number): number | null {
  if (typeof imLastActivityAt === 'number' && Number.isFinite(imLastActivityAt)) {
    return imLastActivityAt;
  }
  const candidates: unknown[] = [
    session.lastActivity,
    session.updated_at,
    session.created_at,
    session.createdAt,
  ];
  for (const v of candidates) {
    if (v === undefined || v === null || v === '') continue;
    let ms: number;
    if (typeof v === 'number') ms = v;
    else if (typeof v === 'string') ms = new Date(v).getTime();
    else if (v instanceof Date) ms = v.getTime();
    else continue;
    if (Number.isFinite(ms)) return ms;
  }
  return null;
}

interface ContactRow {
  id: string;
  projectId: string;
  displayName: string;
  isPinned: boolean;
  preview?: string;
  isOnline?: boolean;
  timestamp: number | null;
}

interface Group {
  projectId: string;
  projectName: string;
  projectPath: string;
  rows: ContactRow[];
  /** Total sessions in the project (before retention filtering). */
  totalSessions: number;
}

interface Props {
  projects: Project[];
  selectedSessionId?: string | null;
  onSelectSession: (sessionId: string, projectId: string) => void;
  /** Opens the project-creation wizard (add a working directory as a contact). */
  onAddContact?: () => void;
  /** IM hub conversations — preview + accurate last-activity + 3-day retention. */
  imConversations?: WireConversation[];
  /** Sessions Claude is actively running (green online dot). */
  liveSessionIds?: Set<string>;
}

function AddContactRow({ onAddContact }: { onAddContact: () => void }) {
  return (
    <button
      type="button"
      onClick={onAddContact}
      className="flex w-full items-center gap-3 border-b border-[var(--wc-border)] px-3 py-2.5 text-left hover:bg-[var(--wc-item-hover)]"
    >
      <span className="flex h-9 w-9 items-center justify-center rounded-md bg-[var(--wc-accent)] text-white">
        <UserPlus className="h-4 w-4" />
      </span>
      <span className="text-[13px] font-medium text-[var(--wc-text-primary)]">添加联系人</span>
    </button>
  );
}

export default function WeChatContactsList({
  projects,
  selectedSessionId,
  onSelectSession,
  onAddContact,
  imConversations,
  liveSessionIds,
}: Props) {
  const imMap = useMemo(
    () => new Map((imConversations ?? []).map((c) => [c.id, c])),
    [imConversations],
  );
  // Re-read pinned set whenever the project list updates (cheap localStorage read);
  // `projects` is referenced inside the body of dependent memos already.
  const pinned = useMemo(() => {
    // Touch `projects` so this memo re-runs when sessions list changes.
    void projects;
    return readPinned();
  }, [projects]);

  const { isPathBlacklisted, toggleBlacklist } = useSessionMeta(imConversations ?? []);

  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggleGroup = (projectId: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(projectId)) next.delete(projectId);
      else next.add(projectId);
      return next;
    });

  const groups = useMemo<Group[]>(() => {
    const cutoff = Date.now() - RETENTION_MS;
    const out: Group[] = [];
    for (const project of projects) {
      // Skip contacts with no working directory (empty path) — not usable.
      const projPath = (project.fullPath ?? project.path ?? '').trim();
      if (!projPath) continue;
      const allSessions = project.sessions ?? [];
      const rows: ContactRow[] = [];
      for (const session of allSessions) {
        const imConv = imMap.get(session.id);
        const isOnline = liveSessionIds?.has(session.id) ?? false;
        const isPinned = pinned.has(session.id);
        const ts = sessionTimestamp(session, imConv?.lastActivityAt);
        // 3-day retention: only list a session if the IM hub still has it, it's
        // live, it's pinned, or its activity is genuinely within the window.
        const recent = ts !== null && ts >= cutoff;
        if (!imConv && !isOnline && !isPinned && !recent) continue;
        rows.push({
          id: session.id,
          projectId: project.projectId,
          displayName: pickDisplayName(session),
          isPinned,
          preview: imConv?.lastMessagePreview?.trim() || undefined,
          isOnline,
          timestamp: ts,
        });
      }
      rows.sort((a, b) => (b.timestamp ?? 0) - (a.timestamp ?? 0));
      // Only show contacts that actually have recent chats — empty / stale-only
      // projects are hidden to cut clutter. (New empty contacts are reachable
      // via the "+" → 发起会话 picker instead.)
      if (rows.length > 0) {
        out.push({
          projectId: project.projectId,
          projectName: (project.displayName ?? project.fullPath ?? '').trim() || '未命名',
          projectPath: projPath,
          rows,
          totalSessions: allSessions.length,
        });
      }
    }
    return out.sort((a, b) => a.projectName.localeCompare(b.projectName, 'zh'));
  }, [projects, pinned, imMap, liveSessionIds]);

  if (groups.length === 0) {
    return (
      <div className="flex h-full w-full flex-col bg-[var(--wc-bg-sidebar)]">
        {onAddContact && <AddContactRow onAddContact={onAddContact} />}
        <div className="flex flex-1 flex-col items-center justify-center gap-2 text-center">
          <Users className="h-8 w-8 text-[var(--wc-text-secondary)] opacity-50" />
          <p className="text-[13px] text-[var(--wc-text-secondary)]">暂无联系人</p>
        </div>
      </div>
    );
  }

  const visibleGroups = groups.filter((g) => !isPathBlacklisted(g.projectPath));

  const renderGroup = (group: Group) => {
    const isCollapsed = collapsed.has(group.projectId);
    return (
      <section key={group.projectId}>
        {/* Collapsible contact (project) header + blacklist action */}
        <div className="sticky top-0 z-10 flex w-full items-center gap-1 bg-[var(--wc-bg-sidebar)] px-3 py-1.5 backdrop-blur hover:bg-[var(--wc-item-hover)]">
          <button
            type="button"
            onClick={() => toggleGroup(group.projectId)}
            className="flex min-w-0 flex-1 items-center gap-1.5 text-left"
          >
            <ChevronRight
              className={`h-3 w-3 shrink-0 text-[var(--wc-text-secondary)] transition-transform ${isCollapsed ? '' : 'rotate-90'}`}
            />
            <span className="flex-1 truncate text-[11px] font-medium uppercase tracking-wider text-[var(--wc-text-secondary)]">
              {group.projectName}
            </span>
            <span className="text-[10px] text-[var(--wc-text-time)]">{group.rows.length}</span>
          </button>
          <button
            type="button"
            title="拉黑此路径（隐藏其下所有会话）"
            onClick={() => toggleBlacklist(group.projectPath)}
            className="shrink-0 rounded p-1 text-[var(--wc-text-secondary)] hover:bg-red-500/10 hover:text-red-500"
          >
            <Ban className="h-3 w-3" />
          </button>
        </div>
        {!isCollapsed && (
          <ul>
            {group.rows.length === 0 ? (
              <li className="px-3 py-2 pl-8 text-[12px] text-[var(--wc-text-time)]">
                暂无会话 · 点「+」发起
              </li>
            ) : (
              group.rows.map((row) => {
                const isSelected = selectedSessionId === row.id;
                return (
                  <li key={row.id}>
                    <button
                      type="button"
                      onClick={() => onSelectSession(row.id, row.projectId)}
                      className={[
                        'flex w-full items-center gap-2.5 px-3 py-2 text-left transition-colors',
                        isSelected ? 'bg-[var(--wc-item-selected)]' : 'hover:bg-[var(--wc-item-hover)]',
                      ].join(' ')}
                    >
                      <div className="relative shrink-0">
                        <WeChatAvatar seed={row.id} title={row.displayName} size={36} />
                        {row.isOnline && (
                          <span className="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full bg-[var(--wc-accent)] ring-2 ring-[var(--wc-bg-sidebar)]" />
                        )}
                      </div>
                      <div className="flex min-w-0 flex-1 flex-col">
                        <div className="flex items-center gap-1">
                          <span className="truncate text-[13px] text-[var(--wc-text-primary)]">
                            {clampNickname(row.displayName)}
                          </span>
                          {row.isPinned && (
                            <Pin className="h-2.5 w-2.5 shrink-0 text-[var(--wc-accent)]" fill="currentColor" />
                          )}
                        </div>
                        {row.preview && (
                          <span className="truncate text-[12px] text-[var(--wc-text-secondary)]">
                            {row.preview}
                          </span>
                        )}
                      </div>
                    </button>
                  </li>
                );
              })
            )}
          </ul>
        )}
      </section>
    );
  };

  return (
    <div className="h-full overflow-y-auto bg-[var(--wc-bg-sidebar)]">
      {onAddContact && <AddContactRow onAddContact={onAddContact} />}
      {visibleGroups.map(renderGroup)}
    </div>
  );
}
