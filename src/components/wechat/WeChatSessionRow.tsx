import { useEffect, useRef, useState } from 'react';
import { BellOff, Pin } from 'lucide-react';

import { clampNickname } from '../../utils/nickname';

import WeChatAvatar from './WeChatAvatar';

// MARK: - WeChatSessionRow
//
// 1:1 port of `Sources/ChatKit/UI/Sidebar/SessionRowView.swift`.
//
// Layout (HSpacing 10):
//   [38px avatar with badge overlay top-right]
//   VStack:
//     line 1: [pin?] [name (1 line truncate)] [mute?] <flex> [relative time]
//     line 2: typing ("对方正在输入...") in green OR latest preview (muted, 1 line)
//
// Hover / selected states match the macOS swatches (#e8e8e8 / #d3d3d3 →
// zinc-200/40 / zinc-300/70 in Tailwind so dark mode also works).
//
// Right-click opens a contextual menu — pin / unpin, mute / unmute, mark read
// (only when `unreadCount > 0`), rename (note), delete. The menu items mirror
// the SwiftUI `.contextMenu` block verbatim.

export interface WeChatSessionRowData {
  /** Stable id used as the avatar hash seed AND as the row selection key. */
  id: string;
  /** Owning project's DB projectId. Forwarded to onSelect for routing. */
  projectId: string;
  /** Display name = note (if set) OR summary OR id-truncated fallback. */
  displayName: string;
  /** Lowercased text used by the parent's search filter (matches Swift's behavior). */
  searchHaystack?: string;
  /** Latest message preview text (line 2). */
  preview?: string;
  /** When `true`, line 2 renders the typing indicator in green instead of preview. */
  isTyping?: boolean;
  /** Live session — Claude is running / recently active. Shows a green dot on
   *  the avatar (WeChat-style online indicator). */
  isOnline?: boolean;
  /** Unread count for the badge overlay. 0 = no badge. */
  unreadCount?: number;
  /** Source-of-truth timestamp for the relative time label. ms epoch or ISO string. */
  lastActivity?: string | number | Date | null;
  isPinned?: boolean;
  isMuted?: boolean;
}

interface Props {
  row: WeChatSessionRowData;
  isSelected: boolean;
  onSelect: (sessionId: string, projectId: string) => void;
  onTogglePin?: (sessionId: string) => void;
  onToggleMute?: (sessionId: string) => void;
  onToggleFold?: (sessionId: string) => void;
  /** Whether this row is currently folded (drives the menu label). */
  isFolded?: boolean;
  /** Blacklist this row's project path (hides every session under it). */
  onBlacklist?: () => void;
  onMarkRead?: (sessionId: string) => void;
  onRename?: (sessionId: string, newName: string) => void;
  onDelete?: (sessionId: string) => void;
}

interface MenuState {
  x: number;
  y: number;
}

/** Mirrors the `relativeTime` computed property in SessionRowView.swift. */
function relativeTime(value: WeChatSessionRowData['lastActivity']): string {
  if (value === undefined || value === null || value === '') {
    return '';
  }
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  const diffSeconds = (Date.now() - date.getTime()) / 1000;
  if (diffSeconds < 60) {
    return '刚刚';
  }
  if (diffSeconds < 3600) {
    return `${Math.floor(diffSeconds / 60)} 分钟前`;
  }
  const now = new Date();
  const isSameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  if (isSameDay) {
    return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  }
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  const isYesterday =
    date.getFullYear() === yesterday.getFullYear() &&
    date.getMonth() === yesterday.getMonth() &&
    date.getDate() === yesterday.getDate();
  if (isYesterday) {
    return '昨天';
  }
  // Within 7 days → 周X
  const diffDays = Math.floor((now.getTime() - date.getTime()) / 86_400_000);
  if (diffDays < 7) {
    const weekdays = ['日', '一', '二', '三', '四', '五', '六'];
    return `周${weekdays[date.getDay()]}`;
  }
  return `${String(date.getMonth() + 1).padStart(2, '0')}/${String(date.getDate()).padStart(2, '0')}`;
}

export default function WeChatSessionRow({
  row,
  isSelected,
  onSelect,
  onTogglePin,
  onToggleMute,
  onToggleFold,
  isFolded,
  onBlacklist,
  onMarkRead,
  onRename,
  onDelete,
}: Props) {
  const [menu, setMenu] = useState<MenuState | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!menu) {
      return;
    }
    const close = (event: MouseEvent) => {
      if (menuRef.current && menuRef.current.contains(event.target as Node)) {
        return;
      }
      setMenu(null);
    };
    const esc = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setMenu(null);
      }
    };
    window.addEventListener('mousedown', close);
    window.addEventListener('keydown', esc);
    return () => {
      window.removeEventListener('mousedown', close);
      window.removeEventListener('keydown', esc);
    };
  }, [menu]);

  const handleContextMenu = (event: React.MouseEvent) => {
    event.preventDefault();
    setMenu({ x: event.clientX, y: event.clientY });
  };

  // Long-press → context menu on touch devices (mobile has no right-click).
  // We open the menu centered near the touch point after a 450ms hold and
  // suppress the subsequent click so it doesn't also select the session.
  const longPressTimer = useRef<number | null>(null);
  const longPressFired = useRef(false);
  const handleTouchStart = (event: React.TouchEvent) => {
    longPressFired.current = false;
    const touch = event.touches[0];
    const x = touch?.clientX ?? 0;
    const y = touch?.clientY ?? 0;
    longPressTimer.current = window.setTimeout(() => {
      longPressFired.current = true;
      // Clamp so the menu stays on-screen.
      const mx = Math.min(x, window.innerWidth - 190);
      const my = Math.min(y, window.innerHeight - 240);
      setMenu({ x: Math.max(8, mx), y: Math.max(8, my) });
    }, 450);
  };
  const clearLongPress = () => {
    if (longPressTimer.current !== null) {
      window.clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  };

  const handleRenameClick = () => {
    setMenu(null);
    if (!onRename) {
      return;
    }
    const next = window.prompt('设置备注名', row.displayName);
    if (next === null) {
      return;
    }
    const trimmed = next.trim();
    onRename(row.id, trimmed);
  };

  const handleDeleteClick = () => {
    setMenu(null);
    onDelete?.(row.id);
  };

  const unread = row.unreadCount ?? 0;
  const timeLabel = relativeTime(row.lastActivity);

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={() => {
        // Swallow the click that follows a long-press menu open.
        if (longPressFired.current) {
          longPressFired.current = false;
          return;
        }
        onSelect(row.id, row.projectId);
      }}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          onSelect(row.id, row.projectId);
        }
      }}
      onContextMenu={handleContextMenu}
      onTouchStart={handleTouchStart}
      onTouchEnd={clearLongPress}
      onTouchMove={clearLongPress}
      onTouchCancel={clearLongPress}
      className={[
        'group flex w-full cursor-pointer items-center gap-2.5 px-3 py-2.5 transition-colors',
        isSelected
          ? 'bg-[var(--wc-item-selected)]'
          : 'hover:bg-[var(--wc-item-hover)]',
      ].join(' ')}
    >
      {/* Avatar + badge overlay */}
      <div className="relative shrink-0">
        <WeChatAvatar seed={row.id} title={row.displayName} size={38} />
        {row.isOnline && (
          <span
            className="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full bg-[var(--wc-accent)] ring-2 ring-[var(--wc-bg-sidebar)]"
            title="在线"
            aria-label="在线"
          />
        )}
        {unread > 0 && (
          <span
            className="absolute -right-1 -top-1 inline-flex min-w-[16px] items-center justify-center rounded-full bg-[var(--wc-badge)] px-1 text-[10px] font-medium leading-none text-white ring-2 ring-[var(--wc-bg-sidebar)]"
            style={{ height: 16 }}
          >
            {unread > 99 ? '99+' : unread}
          </span>
        )}
      </div>

      {/* Right column */}
      <div className="flex min-w-0 flex-1 flex-col gap-[3px]">
        {/* line 1: pin? + name + mute? + time */}
        <div className="flex items-center gap-1">
          {row.isPinned && <Pin className="h-2.5 w-2.5 shrink-0 text-[var(--wc-accent)]" fill="currentColor" />}
          <span className="truncate text-[13px] font-normal text-[var(--wc-text-primary)]">
            {clampNickname(row.displayName)}
          </span>
          {row.isMuted && <BellOff className="h-2.5 w-2.5 shrink-0 text-[var(--wc-text-secondary)]" />}
          <span className="ml-auto shrink-0 pl-2 text-[10px] tabular-nums text-[var(--wc-text-time)]">
            {timeLabel}
          </span>
        </div>
        {/* line 2: typing or preview */}
        {row.isTyping ? (
          <span className="truncate text-[12px] text-[var(--wc-accent)]">对方正在输入...</span>
        ) : row.preview ? (
          <span className="truncate text-[12px] text-[var(--wc-text-secondary)]">{row.preview}</span>
        ) : null}
      </div>

      {/* Context menu */}
      {menu && (
        <div
          ref={menuRef}
          role="menu"
          className="fixed z-50 min-w-[180px] overflow-hidden rounded-md border border-zinc-200 bg-white py-1 text-[13px] text-zinc-700 shadow-lg dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200"
          style={{ left: menu.x, top: menu.y }}
          onClick={(event) => event.stopPropagation()}
        >
          <MenuItem
            label={row.isPinned ? '取消置顶' : '置顶聊天'}
            onClick={() => {
              setMenu(null);
              onTogglePin?.(row.id);
            }}
          />
          <MenuItem
            label={row.isMuted ? '取消静音' : '消息免打扰'}
            onClick={() => {
              setMenu(null);
              onToggleMute?.(row.id);
            }}
          />
          {unread > 0 && (
            <MenuItem
              label="标为已读"
              onClick={() => {
                setMenu(null);
                onMarkRead?.(row.id);
              }}
            />
          )}
          <MenuItem label="设置备注名" onClick={handleRenameClick} />
          {onToggleFold && (
            <MenuItem
              label={isFolded ? '取消折叠' : '折叠聊天'}
              onClick={() => {
                setMenu(null);
                onToggleFold(row.id);
              }}
            />
          )}
          {onBlacklist && (
            <MenuItem
              label="拉黑此项目路径"
              onClick={() => {
                setMenu(null);
                onBlacklist();
              }}
              destructive
            />
          )}
          <div className="my-1 h-px bg-zinc-200 dark:bg-zinc-700" />
          <MenuItem label="删除聊天" onClick={handleDeleteClick} destructive />
        </div>
      )}
    </div>
  );
}

interface MenuItemProps {
  label: string;
  onClick: () => void;
  destructive?: boolean;
}

function MenuItem({ label, onClick, destructive }: MenuItemProps) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className={[
        'block w-full px-3 py-1.5 text-left transition-colors',
        destructive
          ? 'text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-500/10'
          : 'hover:bg-zinc-100 dark:hover:bg-zinc-700/60',
      ].join(' ')}
    >
      {label}
    </button>
  );
}
