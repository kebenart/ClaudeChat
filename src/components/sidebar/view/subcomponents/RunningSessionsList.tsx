import { useEffect, useRef, useState } from 'react';
import { Plus } from 'lucide-react';

import { authenticatedFetch } from '../../../../utils/api';
import type { Project } from '../../../../types/app';

export interface SessionMeta {
  id: string;
  title: string | null;
  project: string | null;
  cwd: string | null;
  projectId: string | null;
  mtime: number | null;
}

interface ActiveSessionsPayload {
  live: SessionMeta[];
  windowMin: number;
}

const POLL_MS = 5000;

function formatRelative(mtime: number | null): string {
  if (!mtime) return '';
  const diffMs = Date.now() - mtime;
  const min = Math.round(diffMs / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.round(hr / 24);
  return `${day}d ago`;
}

function SessionRow({
  session,
  onSelect,
}: {
  session: SessionMeta;
  onSelect: (session: SessionMeta) => void;
}) {
  const title = (session.title && session.title.trim()) || session.id;
  return (
    <li
      onClick={() => onSelect(session)}
      className="group cursor-pointer rounded px-2 py-1.5 hover:bg-accent"
      title={session.id}
    >
      <div className="flex items-center gap-2">
        <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-500" />
        <span className="truncate text-sm font-medium">{title}</span>
      </div>
      <div className="ml-4 flex items-center gap-2 text-xs text-muted-foreground">
        {session.project && <span className="truncate">{session.project}</span>}
        {session.project && session.mtime && <span aria-hidden>·</span>}
        {session.mtime && <span>{formatRelative(session.mtime)}</span>}
      </div>
    </li>
  );
}

function NewChatPopover({
  onNewSession,
  onClose,
}: {
  onNewSession: (project: Project) => void;
  onClose: () => void;
}) {
  const [projects, setProjects] = useState<Project[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    authenticatedFetch('/api/projects')
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json() as Promise<Project[]>;
      })
      .then(setProjects)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, []);

  // Close on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        onClose();
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [onClose]);

  return (
    <div
      ref={ref}
      className="absolute left-2 right-2 top-full z-50 mt-1 rounded-md border border-border bg-popover shadow-lg"
    >
      <div className="max-h-64 overflow-y-auto p-1">
        {error ? (
          <p className="px-2 py-2 text-xs text-red-500">Error: {error}</p>
        ) : projects === null ? (
          <p className="px-2 py-2 text-xs text-muted-foreground">Loading projects…</p>
        ) : projects.length === 0 ? (
          <p className="px-2 py-2 text-xs text-muted-foreground">
            No projects yet. Create one via CommandPalette (Cmd+K) → New project.
          </p>
        ) : (
          projects.map((project) => (
            <button
              key={project.projectId}
              className="flex w-full flex-col rounded px-2 py-1.5 text-left hover:bg-accent"
              onClick={() => {
                onNewSession(project);
                onClose();
              }}
            >
              <span className="truncate text-sm font-medium">{project.displayName}</span>
              <span className="truncate text-xs text-muted-foreground">{project.fullPath}</span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}

export function RunningSessionsList({
  onSelect,
  onNewSession,
}: {
  onSelect: (session: SessionMeta) => void;
  onNewSession?: (project: Project) => void;
}) {
  const [data, setData] = useState<ActiveSessionsPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [popoverOpen, setPopoverOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const res = await authenticatedFetch('/api/sessions/active');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const next: ActiveSessionsPayload = await res.json();
        if (!cancelled) {
          setData(next);
          setError(null);
        }
      } catch (e: unknown) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    };
    void tick();
    const id = setInterval(tick, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const empty = !data || data.live.length === 0;

  return (
    <div className="space-y-2 p-2">
      {/* New Chat button */}
      {onNewSession && (
        <div className="relative">
          <button
            className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-sm text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => setPopoverOpen((v) => !v)}
          >
            <Plus className="h-4 w-4 flex-shrink-0" />
            <span>New chat</span>
          </button>
          {popoverOpen && (
            <NewChatPopover
              onNewSession={onNewSession}
              onClose={() => setPopoverOpen(false)}
            />
          )}
        </div>
      )}

      {/* Live sessions section */}
      {error ? (
        <div className="p-1 text-red-500 text-sm">Error: {error}</div>
      ) : !data ? (
        <div className="p-1 text-zinc-400 text-sm">Loading…</div>
      ) : empty ? (
        <div className="p-1 text-zinc-400 text-sm">
          No live Claude sessions. Start one with <code>claude</code> in any project, or click + to start a new chat.
        </div>
      ) : (
        <section>
          <h3 className="mb-1 px-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Live
          </h3>
          <ul className="space-y-1">
            {data.live.map(session => (
              <SessionRow
                key={session.id}
                session={session}
                onSelect={onSelect}
              />
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
