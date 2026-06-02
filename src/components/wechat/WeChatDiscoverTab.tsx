import { useEffect, useMemo, useState } from 'react';
import { Compass, Search, Sparkles, Command as CmdIcon, X } from 'lucide-react';

import { authenticatedFetch } from '../../utils/api';

// MARK: - WeChatDiscoverTab
//
// The "发现" tab is a Claude Code-flavored "discover" surface — it lists
// available slash commands, skills, and MCP plugins. Tapping a row inserts
// it into the active composer draft for the currently selected session.
//
// This is NOT WeChat's Moments feature; it's a directory of Claude Code
// capabilities the user can drop into a chat.

interface CommandInfo {
  name: string;
  description: string;
  /** "skill" | "builtin" | "custom" */
  namespace?: string;
}

interface SkillInfo {
  name?: string;
  command?: string;
  description?: string;
}

interface Props {
  /** Whether the current viewport collapses to a single column. */
  isMobile: boolean;
  /** Selected session — we need its id to write the composer draft. */
  selectedSessionId?: string | null;
  /** Called when the user picks a command — insert it into the composer. */
  onInsertIntoComposer: (text: string) => void;
}

type DiscoverItem = {
  id: string;
  type: 'skill' | 'command';
  name: string;
  description: string;
};

function commandsToItems(builtIn: CommandInfo[], custom: CommandInfo[]): DiscoverItem[] {
  const seen = new Set<string>();
  const out: DiscoverItem[] = [];
  for (const c of [...builtIn, ...custom]) {
    if (seen.has(c.name)) continue;
    seen.add(c.name);
    out.push({
      id: `cmd-${c.name}`,
      type: 'command',
      name: c.name,
      description: c.description || '',
    });
  }
  return out;
}

function skillsToItems(skills: SkillInfo[]): DiscoverItem[] {
  const seen = new Set<string>();
  const out: DiscoverItem[] = [];
  for (const s of skills) {
    const name = s.command || (s.name ? (s.name.startsWith('/') ? s.name : `/${s.name}`) : '');
    if (!name || seen.has(name)) continue;
    seen.add(name);
    out.push({
      id: `skill-${name}`,
      type: 'skill',
      name,
      description: s.description || '',
    });
  }
  return out;
}

export default function WeChatDiscoverTab({ isMobile, selectedSessionId, onInsertIntoComposer }: Props) {
  const [skills, setSkills] = useState<DiscoverItem[]>([]);
  const [commands, setCommands] = useState<DiscoverItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [selectedTab, setSelectedTab] = useState<'skill' | 'command'>('skill');

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    void (async () => {
      try {
        const [skillsResp, commandsResp] = await Promise.all([
          authenticatedFetch('/api/providers/claude/skills'),
          authenticatedFetch('/api/commands/list', { method: 'POST', body: JSON.stringify({}), headers: { 'Content-Type': 'application/json' } }),
        ]);
        const skillsJson = (await skillsResp.json()) as { success?: boolean; data?: { skills?: SkillInfo[] } };
        const cmdJson = (await commandsResp.json()) as { builtIn?: CommandInfo[]; custom?: CommandInfo[] };
        if (cancelled) return;
        setSkills(skillsToItems(skillsJson?.data?.skills ?? []));
        setCommands(commandsToItems(cmdJson?.builtIn ?? [], cmdJson?.custom ?? []));
      } catch (err) {
        if (!cancelled) {
          setError('加载失败: ' + (err instanceof Error ? err.message : String(err)));
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const items = selectedTab === 'skill' ? skills : commands;
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return items;
    return items.filter((it) =>
      it.name.toLowerCase().includes(q) || it.description.toLowerCase().includes(q),
    );
  }, [items, search]);

  const handlePick = (item: DiscoverItem) => {
    if (!selectedSessionId) {
      // Tell the user that they need a session selected first.
      window.alert('请先在「聊天」或「通讯录」里选择一个会话,再插入命令到输入框。');
      return;
    }
    onInsertIntoComposer(item.name + ' ');
  };

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col bg-zinc-50 dark:bg-zinc-950">
      {/* Header — toggle skills vs commands + search */}
      <div className="flex shrink-0 flex-col gap-2 border-b border-zinc-200 bg-zinc-100 px-4 py-3 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex items-center gap-2">
          <Compass className="h-4 w-4 text-emerald-600" />
          <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">发现</h2>
          <span className="text-[11px] text-zinc-500">Claude Code 技能与命令</span>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setSelectedTab('skill')}
            className={`rounded-full px-3 py-0.5 text-[11px] ${
              selectedTab === 'skill'
                ? 'bg-emerald-600 text-white'
                : 'bg-zinc-200 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300'
            }`}
          >
            技能 {skills.length > 0 && `(${skills.length})`}
          </button>
          <button
            type="button"
            onClick={() => setSelectedTab('command')}
            className={`rounded-full px-3 py-0.5 text-[11px] ${
              selectedTab === 'command'
                ? 'bg-emerald-600 text-white'
                : 'bg-zinc-200 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300'
            }`}
          >
            命令 {commands.length > 0 && `(${commands.length})`}
          </button>
        </div>
        <div className="flex items-center gap-2 rounded-md bg-white px-2 py-1 dark:bg-zinc-800">
          <Search className="h-3.5 w-3.5 text-zinc-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="搜索技能或命令"
            className="w-0 flex-1 bg-transparent text-[12px] outline-none placeholder:text-zinc-400"
          />
          {search && (
            <button type="button" onClick={() => setSearch('')} className="text-zinc-400 hover:text-zinc-600">
              <X className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
      </div>

      {/* List */}
      <div className="flex-1 overflow-y-auto">
        {loading ? (
          <div className="flex h-full items-center justify-center text-[12px] text-zinc-500">加载中...</div>
        ) : error ? (
          <div className="flex h-full items-center justify-center text-[12px] text-red-500">{error}</div>
        ) : filtered.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center gap-2 text-zinc-400">
            <Sparkles className="h-8 w-8" />
            <span className="text-[12px]">无匹配结果</span>
          </div>
        ) : (
          <ul className="divide-y divide-zinc-200/60 dark:divide-zinc-800/60">
            {filtered.map((item) => (
              <li key={item.id}>
                <button
                  type="button"
                  onClick={() => handlePick(item)}
                  className="flex w-full items-start gap-3 px-4 py-3 text-left hover:bg-zinc-100 dark:hover:bg-zinc-900"
                >
                  <div className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-emerald-100 dark:bg-emerald-900/30">
                    {item.type === 'skill' ? (
                      <Sparkles className="h-4 w-4 text-emerald-600" />
                    ) : (
                      <CmdIcon className="h-4 w-4 text-emerald-600" />
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="truncate font-mono text-[13px] font-medium text-zinc-900 dark:text-zinc-100">
                      {item.name}
                    </div>
                    {item.description && (
                      <div className="mt-0.5 text-[11px] text-zinc-500 dark:text-zinc-400 line-clamp-2">
                        {item.description}
                      </div>
                    )}
                  </div>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      {!isMobile && (
        <div className="shrink-0 border-t border-zinc-200 bg-zinc-100 px-4 py-2 text-[10px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          点击一项把它写入当前会话的输入框
        </div>
      )}
    </div>
  );
}
