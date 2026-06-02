import { useEffect, useMemo, useRef, useState } from 'react';
import { Command } from 'lucide-react';

import { authenticatedFetch } from '../../utils/api';

// MARK: - WeChatSlashCommandPicker
//
// Mirrors the SwiftUI `SlashCommandPicker` (mac app) — a popover anchored under
// the composer's `/` toolbar button. Reads:
//   POST /api/commands/list { projectPath } → { builtIn, custom, count }
//   GET  /api/providers/claude/skills?workspacePath=... → { provider, skills }
//
// Up/Down arrows navigate. Enter inserts. Escape closes.

export interface WeChatCommand {
  /** Begins with `/`, e.g. `/help` or `/rewind`. */
  name: string;
  description?: string;
  namespace?: string;
  source?: 'builtin' | 'project' | 'user' | 'skill';
}

interface Props {
  projectPath?: string | null;
  query: string;
  onPick: (cmd: WeChatCommand) => void;
  onClose: () => void;
  /** Optional anchor element; the picker positions itself just below this. */
  anchorEl?: HTMLElement | null;
}

interface BuiltinResponse {
  builtIn?: WeChatCommand[];
  custom?: WeChatCommand[];
}

interface SkillsResponse {
  data?: { skills?: Array<{ name?: string; description?: string }> };
}

async function loadAll(projectPath?: string | null): Promise<WeChatCommand[]> {
  const list: WeChatCommand[] = [];
  // Commands: POST with optional projectPath.
  try {
    const r = await authenticatedFetch('/api/commands/list', {
      method: 'POST',
      body: JSON.stringify({ projectPath: projectPath ?? null }),
    });
    if (r.ok) {
      const data = (await r.json()) as BuiltinResponse;
      for (const cmd of data.builtIn ?? []) {
        list.push({ ...cmd, source: 'builtin' });
      }
      for (const cmd of data.custom ?? []) {
        list.push({
          ...cmd,
          source: cmd.namespace === 'user' ? 'user' : 'project',
        });
      }
    }
  } catch {
    // ignore — skill list still loads
  }
  // Skills: GET with optional workspacePath. Each skill becomes /<name>.
  try {
    const url = projectPath
      ? `/api/providers/claude/skills?workspacePath=${encodeURIComponent(projectPath)}`
      : '/api/providers/claude/skills';
    const r = await authenticatedFetch(url);
    if (r.ok) {
      const data = (await r.json()) as SkillsResponse;
      for (const skill of data.data?.skills ?? []) {
        const name = (skill.name ?? '').trim();
        if (!name) continue;
        list.push({
          name: name.startsWith('/') ? name : `/${name}`,
          description: skill.description,
          source: 'skill',
        });
      }
    }
  } catch {
    // ignore
  }
  // Dedupe by name; first-write wins.
  const seen = new Set<string>();
  return list.filter((cmd) => {
    if (seen.has(cmd.name)) return false;
    seen.add(cmd.name);
    return true;
  });
}

function sourceLabel(source: WeChatCommand['source']): string {
  switch (source) {
    case 'builtin':
      return '内置';
    case 'user':
      return '用户';
    case 'project':
      return '项目';
    case 'skill':
      return '技能';
    default:
      return '';
  }
}

export default function WeChatSlashCommandPicker({
  projectPath,
  query,
  onPick,
  onClose,
  anchorEl,
}: Props) {
  const [all, setAll] = useState<WeChatCommand[]>([]);
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLDivElement | null>(null);
  const [coords, setCoords] = useState<{ left: number; top: number } | null>(null);

  // Compute anchor position relative to viewport.
  useEffect(() => {
    if (!anchorEl) {
      setCoords(null);
      return;
    }
    const rect = anchorEl.getBoundingClientRect();
    setCoords({ left: rect.left, top: rect.bottom + 4 });
  }, [anchorEl]);

  useEffect(() => {
    void (async () => {
      const list = await loadAll(projectPath);
      setAll(list);
    })();
  }, [projectPath]);

  const filtered = useMemo(() => {
    const q = query.replace(/^\//, '').toLowerCase().trim();
    if (!q) return all.slice(0, 30);
    return all.filter((c) => c.name.slice(1).toLowerCase().includes(q)).slice(0, 30);
  }, [all, query]);

  // Reset active index whenever the filter changes.
  useEffect(() => {
    setActive(0);
  }, [query]);

  // Keyboard navigation.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        setActive((i) => Math.min(filtered.length - 1, i + 1));
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        setActive((i) => Math.max(0, i - 1));
      } else if (e.key === 'Enter') {
        if (filtered.length > 0) {
          e.preventDefault();
          onPick(filtered[Math.min(active, filtered.length - 1)]);
        }
      } else if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [filtered, active, onPick, onClose]);

  // Scroll active item into view.
  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const item = list.querySelector<HTMLElement>(`[data-idx="${active}"]`);
    item?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  if (filtered.length === 0) {
    return null;
  }

  const style: React.CSSProperties = coords
    ? { position: 'fixed', left: coords.left, top: coords.top, zIndex: 50 }
    : { position: 'absolute', bottom: '100%', left: 0, zIndex: 50, marginBottom: 4 };

  return (
    <div
      style={style}
      className="w-[300px] overflow-hidden rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
      onMouseDown={(e) => e.preventDefault()}
    >
      <div className="flex items-center gap-1.5 border-b border-zinc-100 px-3 py-1.5 text-[10px] uppercase tracking-wider text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
        <Command className="h-3 w-3" />
        Claude Code 命令
        <span className="ml-auto normal-case">{filtered.length} 项</span>
      </div>
      <div ref={listRef} className="max-h-[260px] overflow-y-auto py-1">
        {filtered.map((cmd, idx) => (
          <button
            type="button"
            key={cmd.name + idx}
            data-idx={idx}
            onMouseEnter={() => setActive(idx)}
            onClick={() => onPick(cmd)}
            className={[
              'flex w-full items-start gap-2 px-3 py-1.5 text-left',
              idx === active
                ? 'bg-zinc-100 dark:bg-zinc-800'
                : 'hover:bg-zinc-100 dark:hover:bg-zinc-800',
            ].join(' ')}
          >
            <span className="font-mono text-[12px] text-zinc-900 dark:text-zinc-100">
              {cmd.name}
            </span>
            {cmd.description && (
              <span className="flex-1 truncate text-[11px] text-zinc-500 dark:text-zinc-400">
                {cmd.description}
              </span>
            )}
            {cmd.source && (
              <span className="rounded bg-zinc-200/70 px-1 py-px text-[9px] text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">
                {sourceLabel(cmd.source)}
              </span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}
