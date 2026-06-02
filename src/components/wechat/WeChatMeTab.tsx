import { useEffect, useState } from 'react';
import {
  Activity,
  Bell,
  ChevronRight,
  Gauge,
  Globe,
  Info,
  Loader2,
  LogOut,
  Moon,
  RefreshCw,
  Server,
  Shield,
  User as UserIcon,
  Wifi,
  WifiOff,
} from 'lucide-react';

import type { ConnectionStatus } from '../../contexts/WebSocketContext';
import {
  fetchClaudeUsageLimits,
  fetchClaudePing,
  type ClaudeUsageLimits,
  type ClaudeUsageWindow,
  type ClaudePing,
} from '../../services/im/api';
import { useAuth } from '../auth';

import WeChatAvatar from './WeChatAvatar';
import { useSessionMeta } from './useSessionMeta';

// MARK: - WeChatMeTab
//
// Claude Code "我" surface. Top profile card + grouped settings rows.
// Mirrors macOS MeSidebar.swift. None of the rows have heavy editors yet —
// each is a placeholder that explains what it WILL show, so the user can
// see the structure without us shipping every settings screen at once.

interface Props {
  connectionStatus: ConnectionStatus;
  reconnectAttempt: number;
  /** Live WS round-trip latency in ms (null until first sample / offline). */
  latencyMs?: number | null;
  /** Trigger an immediate ping to refresh the latency reading. */
  onPing?: () => void;
  isMobile: boolean;
  onLogout?: () => void;
}

// ping latency → label + tailwind text color. Green is snappy, amber is okay,
// red is laggy. null means "no sample yet" (measuring).
function latencyTone(ms: number | null | undefined): { color: string; label: string } {
  if (ms == null) return { color: 'text-zinc-400 dark:text-zinc-500', label: '测速中…' };
  if (ms < 100) return { color: 'text-emerald-500', label: `${ms} ms` };
  if (ms < 300) return { color: 'text-amber-500', label: `${ms} ms` };
  return { color: 'text-red-500', label: `${ms} ms` };
}

// Hub→Claude-server RTT. The proxy path (which real API calls also use) is
// inherently slow — a healthy proxy reach is routinely ~5-6s, so a flat 500ms
// red threshold would brand a perfectly working link red. Use proxy-aware
// thresholds: looser when via:'proxy', tight when via:'direct'. null = measuring;
// an unreachable probe (ok:false) shows 不可达.
function claudeTone(ping: ClaudePing | null | undefined): { color: string; label: string } {
  if (ping == null) return { color: 'text-zinc-400 dark:text-zinc-500', label: '测速中…' };
  if (!ping.ok || ping.ms == null) return { color: 'text-red-500', label: '不可达' };
  // Proxy reach is ~5-6s when healthy; direct reach is sub-second.
  const [good, ok] = ping.via === 'proxy' ? [4000, 9000] : [200, 500];
  if (ping.ms < good) return { color: 'text-emerald-500', label: `${ping.ms} ms` };
  if (ping.ms < ok) return { color: 'text-amber-500', label: `${ping.ms} ms` };
  return { color: 'text-red-500', label: `${ping.ms} ms` };
}

type Section =
  | 'profile'
  | 'account'
  | 'notifications'
  | 'appearance'
  | 'server'
  | 'about'
  | 'logout';

interface Row {
  section: Section;
  icon: typeof UserIcon;
  title: string;
  subtitle?: string;
  destructive?: boolean;
}

export default function WeChatMeTab({ connectionStatus, reconnectAttempt, latencyMs, onPing, isMobile, onLogout }: Props) {
  const { user, logout } = useAuth();
  const { blacklist, toggleBlacklist } = useSessionMeta();
  const [openSection, setOpenSection] = useState<Section | null>(null);

  // Read-only Claude usage limits (5h / 7d). Server caches 30min; manual refresh
  // re-asks with ?force=1 (server still floors actual upstream calls at 5min).
  const [usage, setUsage] = useState<ClaudeUsageLimits | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  // Hub→Claude-server reachability (REST probe; the hub measures it because the
  // client can't reach api.anthropic.com directly, esp. in CN).
  const [claudePing, setClaudePing] = useState<ClaudePing | null>(null);
  const [pingingClaude, setPingingClaude] = useState(false);
  const probeClaude = async () => {
    if (pingingClaude) return;
    setPingingClaude(true);
    try {
      setClaudePing(await fetchClaudePing());
    } finally {
      setPingingClaude(false);
    }
  };
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const limits = await fetchClaudeUsageLimits();
      if (!cancelled) setUsage(limits);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  const refreshUsage = async () => {
    if (refreshing) return;
    setRefreshing(true);
    try {
      setUsage(await fetchClaudeUsageLimits(true));
    } finally {
      setRefreshing(false);
    }
  };

  // Probe latency immediately whenever we (re)enter the online state — the
  // background heartbeat only fires every 25s, too slow for an at-a-glance read.
  // Also probe the hub→Claude-server RTT once here (REST, independent of the WS).
  useEffect(() => {
    if (connectionStatus !== 'online') return;
    onPing?.();
    let cancelled = false;
    void (async () => {
      const p = await fetchClaudePing();
      if (!cancelled) setClaudePing(p);
    })();
    return () => {
      cancelled = true;
    };
  }, [connectionStatus, onPing]);

  const sectionsGroup1: Row[] = [
    { section: 'account', icon: Shield, title: '账号信息', subtitle: user?.username ?? '未登录' },
    { section: 'notifications', icon: Bell, title: '新消息通知' },
  ];
  const sectionsGroup2: Row[] = [
    { section: 'appearance', icon: Moon, title: '通用 / 外观' },
    { section: 'server', icon: Server, title: '服务器配置' },
  ];
  const sectionsGroup3: Row[] = [
    { section: 'about', icon: Info, title: '关于 Claude Chat' },
    { section: 'logout', icon: LogOut, title: '退出登录', destructive: true },
  ];

  const handleRow = (row: Row) => {
    if (row.section === 'logout') {
      void (async () => {
        await logout();
        onLogout?.();
      })();
      return;
    }
    setOpenSection((cur) => (cur === row.section ? null : row.section));
  };

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col bg-zinc-100 dark:bg-zinc-900">
      {/* Profile card */}
      <div className="flex shrink-0 items-center gap-3 bg-white px-4 py-4 dark:bg-zinc-950">
        <WeChatAvatar
          seed={user?.username ? `user-${user.username}` : 'me'}
          title={user?.username ?? 'Me'}
          size={56}
        />
        <div className="min-w-0 flex-1">
          <div className="truncate text-base font-semibold text-zinc-900 dark:text-zinc-100">
            {user?.username ?? '未登录'}
          </div>
          <div className="mt-0.5 flex items-center gap-1 text-[11px] text-zinc-500 dark:text-zinc-400">
            {connectionStatus === 'online' ? (
              <>
                <Wifi className="h-3 w-3 text-emerald-500" />
                已连接服务端
                <button
                  type="button"
                  onClick={() => onPing?.()}
                  title="点击重新测速"
                  className="ml-1 inline-flex items-center gap-0.5 rounded-full bg-zinc-100 px-1.5 py-px font-medium tabular-nums transition-colors hover:bg-zinc-200 dark:bg-zinc-800 dark:hover:bg-zinc-700"
                >
                  <Activity className={`h-2.5 w-2.5 ${latencyTone(latencyMs).color}`} />
                  <span className={latencyTone(latencyMs).color}>{latencyTone(latencyMs).label}</span>
                </button>
                <button
                  type="button"
                  onClick={() => void probeClaude()}
                  disabled={pingingClaude}
                  title="到 Claude 服务器的网络延迟 · 点击重测"
                  className="ml-1 inline-flex items-center gap-0.5 rounded-full bg-zinc-100 px-1.5 py-px font-medium tabular-nums transition-colors hover:bg-zinc-200 disabled:opacity-60 dark:bg-zinc-800 dark:hover:bg-zinc-700"
                >
                  <Globe className={`h-2.5 w-2.5 ${claudeTone(claudePing).color}`} />
                  <span className={claudeTone(claudePing).color}>{claudeTone(claudePing).label}</span>
                </button>
              </>
            ) : connectionStatus === 'reconnecting' ? (
              <>
                <Loader2 className="h-3 w-3 animate-spin text-amber-500" />
                重连中{reconnectAttempt > 0 ? `·第 ${reconnectAttempt} 次` : '…'}
              </>
            ) : (
              <>
                <WifiOff className="h-3 w-3 text-zinc-400" />
                已离线 · 网络不可用
              </>
            )}
          </div>
        </div>
      </div>

      {/* Settings groups */}
      <div className="flex-1 overflow-y-auto px-3 py-3">
        {/* 用量 — read-only Claude usage limits (5h / 7d). */}
        <UsageCard usage={usage} refreshing={refreshing} onRefresh={refreshUsage} />
        <div className="h-3" />
        <SettingsGroup rows={sectionsGroup1} openSection={openSection} onRow={handleRow} />
        <div className="h-3" />
        <SettingsGroup rows={sectionsGroup2} openSection={openSection} onRow={handleRow} />
        <div className="h-3" />
        <SettingsGroup rows={sectionsGroup3} openSection={openSection} onRow={handleRow} />

        {openSection && openSection !== 'logout' && (
          <DetailCard section={openSection} username={user?.username} />
        )}

        {/* Blacklist management — un-blacklist project paths hidden from the lists. */}
        <div className="mt-3 overflow-hidden rounded-lg border border-zinc-200/70 bg-white dark:border-zinc-800 dark:bg-zinc-950">
          <div className="border-b border-zinc-100 px-3 py-2 text-[12px] font-medium text-zinc-700 dark:border-zinc-800 dark:text-zinc-200">
            黑名单路径
            <span className="ml-1 text-[11px] font-normal text-zinc-400">{blacklist.size}</span>
          </div>
          {blacklist.size === 0 ? (
            <p className="px-3 py-3 text-[11px] text-zinc-500 dark:text-zinc-400">
              暂无。在「通讯录」的项目右侧点 🚫 或在会话右键「拉黑此项目路径」即可添加，拉黑后其下所有会话不再显示。
            </p>
          ) : (
            <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {Array.from(blacklist)
                .sort()
                .map((path) => (
                  <li key={path} className="flex items-center gap-2 px-3 py-2">
                    <span className="min-w-0 flex-1 truncate font-mono text-[11px] text-zinc-700 dark:text-zinc-300">
                      {path}
                    </span>
                    <button
                      type="button"
                      onClick={() => toggleBlacklist(path)}
                      className="shrink-0 rounded px-2 py-0.5 text-[11px] text-emerald-600 hover:bg-emerald-50 dark:hover:bg-emerald-500/10"
                    >
                      解除
                    </button>
                  </li>
                ))}
            </ul>
          )}
        </div>
      </div>

      {!isMobile && (
        <div className="shrink-0 border-t border-zinc-200 px-4 py-2 text-[10px] text-zinc-500 dark:border-zinc-800">
          Claude Chat · WeChat-style UI · Claude Code CLI 客户端
        </div>
      )}
    </div>
  );
}

// MARK: - 用量 card
//
// Read-only Claude usage windows (5 小时 / 7 天). Each row shows X% + a thin
// load-colored bar + the local reset time. "暂无数据" when a window is null.

function loadColor(pct: number): string {
  if (pct >= 90) return 'bg-red-500';
  if (pct >= 70) return 'bg-amber-500';
  return 'bg-emerald-500';
}

// The 5h window resets today (time is enough); the 7d window resets days out,
// so a bare "00:00" is meaningless — prepend the date unless it's today.
function formatResetTime(rfc3339: string): string | null {
  const d = new Date(rfc3339);
  if (Number.isNaN(d.getTime())) return null;
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return time;
  const date = d.toLocaleDateString([], { month: 'numeric', day: 'numeric' });
  return `${date} ${time}`;
}

function formatAsOf(asOf: number | undefined): string | null {
  if (typeof asOf !== 'number') return null;
  const d = new Date(asOf);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function UsageRow({ label, window }: { label: string; window: ClaudeUsageWindow | null }) {
  if (!window) {
    return (
      <div className="flex items-center justify-between gap-3 px-3 py-2.5">
        <span className="text-[12px] text-zinc-700 dark:text-zinc-300">{label}</span>
        <span className="text-[11px] text-zinc-400 dark:text-zinc-500">暂无数据</span>
      </div>
    );
  }
  const pct = Math.max(0, Math.min(100, Math.round(window.utilizationPct)));
  const reset = formatResetTime(window.resetsAt);
  return (
    <div className="px-3 py-2.5">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[12px] text-zinc-700 dark:text-zinc-300">{label}</span>
        <span className="text-[12px] font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
          {pct}%
        </span>
      </div>
      <div className="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800">
        <div
          className={`h-full rounded-full ${loadColor(pct)}`}
          style={{ width: `${pct}%` }}
        />
      </div>
      {reset && (
        <div className="mt-1 text-[10px] text-zinc-400 dark:text-zinc-500">重置于 {reset}</div>
      )}
    </div>
  );
}

function UsageCard({
  usage,
  refreshing,
  onRefresh,
}: {
  usage: ClaudeUsageLimits | null;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const asOf = formatAsOf(usage?.asOf);
  return (
    <div className="overflow-hidden rounded-lg border border-zinc-200/70 bg-white dark:border-zinc-800 dark:bg-zinc-950">
      <div className="flex items-center gap-1.5 border-b border-zinc-100 px-3 py-2 text-[12px] font-medium text-zinc-700 dark:border-zinc-800 dark:text-zinc-200">
        <Gauge className="h-3.5 w-3.5 text-emerald-600" />
        用量
        <div className="ml-auto flex items-center gap-2">
          {asOf && (
            <span className="text-[10px] font-normal text-zinc-400 dark:text-zinc-500">
              更新于 {asOf}
            </span>
          )}
          <button
            type="button"
            onClick={onRefresh}
            disabled={refreshing}
            title="刷新(最低间隔 5 分钟)"
            className="text-zinc-400 transition-colors hover:text-emerald-600 disabled:opacity-50 dark:text-zinc-500"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${refreshing ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>
      <UsageRow label="5 小时" window={usage?.fiveHour ?? null} />
      <div className="h-px bg-zinc-100 dark:bg-zinc-800" />
      <UsageRow label="7 天" window={usage?.sevenDay ?? null} />
    </div>
  );
}

function SettingsGroup({
  rows,
  openSection,
  onRow,
}: {
  rows: Row[];
  openSection: Section | null;
  onRow: (row: Row) => void;
}) {
  return (
    <div className="overflow-hidden rounded-lg border border-zinc-200/70 bg-white dark:border-zinc-800 dark:bg-zinc-950">
      {rows.map((row, i) => {
        const Icon = row.icon;
        const isActive = openSection === row.section;
        return (
          <button
            key={row.section}
            type="button"
            onClick={() => onRow(row)}
            className={`flex w-full items-center gap-3 px-3 py-3 text-left transition-colors ${
              isActive ? 'bg-zinc-100 dark:bg-zinc-900' : 'hover:bg-zinc-50 dark:hover:bg-zinc-900/60'
            } ${i !== rows.length - 1 ? 'border-b border-zinc-100 dark:border-zinc-800' : ''}`}
          >
            <Icon
              className={`h-4 w-4 ${
                row.destructive ? 'text-red-500' : 'text-emerald-600'
              }`}
            />
            <div className="flex min-w-0 flex-1 flex-col">
              <span
                className={`text-[13px] ${
                  row.destructive ? 'text-red-500' : 'text-zinc-900 dark:text-zinc-100'
                }`}
              >
                {row.title}
              </span>
              {row.subtitle && (
                <span className="truncate text-[11px] text-zinc-500 dark:text-zinc-400">
                  {row.subtitle}
                </span>
              )}
            </div>
            <ChevronRight className="h-3 w-3 text-zinc-400" />
          </button>
        );
      })}
    </div>
  );
}

function DetailCard({ section, username }: { section: Section; username?: string }) {
  const content: Record<Exclude<Section, 'logout' | 'profile'>, { title: string; body: string }> = {
    account: {
      title: '账号信息',
      body: `当前登录账号: ${username ?? '未知'}。TOTP / 密码修改 / 设备管理在下一阶段接入 /api/auth/* 后开放。`,
    },
    notifications: {
      title: '新消息通知',
      body: '浏览器端使用 Notification API。如关闭可在浏览器地址栏左侧的通知设置中关闭。会话维度的免打扰跟服务端的 isMuted 字段联动。',
    },
    appearance: {
      title: '通用 / 外观',
      body: '主题色固定为微信绿 (#07C160)。深色模式跟随系统。字号 / 间距 / 头像 hash 调色板与 macOS 版本一致。',
    },
    server: {
      title: '服务器配置',
      body: '后端地址来自当前 host (浏览器同源)。开发模式启用 DEV_AUTH_BYPASS=1 可免登录。生产部署请关闭并通过 TOTP 双因素登录。',
    },
    about: {
      title: '关于 Claude Chat',
      body: 'Claude Code CLI 客户端 · 仿微信交互 · 后端基于 claudecodeui-local fork。版本号见 package.json。',
    },
  };
  const c = content[section as Exclude<Section, 'logout' | 'profile'>];
  if (!c) return null;
  return (
    <div className="mt-3 rounded-lg border border-emerald-200/60 bg-emerald-50/40 p-3 text-[12px] text-zinc-700 dark:border-emerald-900/40 dark:bg-emerald-950/30 dark:text-zinc-200">
      <div className="mb-1 font-medium text-emerald-800 dark:text-emerald-300">{c.title}</div>
      <p className="leading-relaxed">{c.body}</p>
    </div>
  );
}
