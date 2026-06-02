import { useMemo, useState } from 'react';
import { Search, UserPlus, X } from 'lucide-react';

import type { Project } from '../../types/app';

import WeChatAvatar from './WeChatAvatar';

// MARK: - WeChatNewSessionPopover
//
// "新建会话" sheet — mirrors the macOS NewSessionPopover. Lists contacts
// (projects/working directories), filterable by name, plus an "添加联系人"
// action that opens the project-creation wizard. Picking a contact starts a
// fresh chat in that project (the session id is assigned by the server on the
// first send).

interface Props {
  projects: Project[];
  onPickContact: (project: Project) => void;
  onAddContact: () => void;
  onClose: () => void;
}

export default function WeChatNewSessionPopover({
  projects,
  onPickContact,
  onAddContact,
  onClose,
}: Props) {
  const [search, setSearch] = useState('');

  const filtered = useMemo(() => {
    // Only contacts with a real working directory (non-empty path) are usable.
    const list = projects.filter((p) => (p.fullPath ?? p.path ?? '').trim().length > 0);
    const needle = search.trim().toLowerCase();
    if (!needle) return list;
    return list.filter((p) =>
      `${p.displayName ?? ''} ${p.fullPath ?? ''}`.toLowerCase().includes(needle),
    );
  }, [projects, search]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="flex max-h-[70vh] w-full max-w-md flex-col overflow-hidden rounded-lg bg-[var(--wc-bg-app)] shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b border-[var(--wc-border)] px-4 py-3">
          <span className="text-[14px] font-medium text-[var(--wc-text-primary)]">发起会话</span>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            aria-label="关闭"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {/* Search */}
        <div className="px-3 pt-3">
          <div className="flex items-center gap-1.5 rounded-[5px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] px-2 py-1.5">
            <Search className="h-3.5 w-3.5 shrink-0 text-[var(--wc-text-secondary)]" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="搜索联系人"
              autoFocus
              className="min-w-0 flex-1 bg-transparent text-[13px] text-[var(--wc-text-primary)] outline-none placeholder:text-[var(--wc-text-secondary)]"
            />
          </div>
        </div>

        {/* Add contact */}
        <button
          type="button"
          onClick={onAddContact}
          className="mx-3 mt-3 flex items-center gap-3 rounded-md px-2 py-2 text-left hover:bg-[var(--wc-item-hover)]"
        >
          <span className="flex h-9 w-9 items-center justify-center rounded-md bg-[var(--wc-accent)] text-white">
            <UserPlus className="h-4 w-4" />
          </span>
          <span className="text-[13px] font-medium text-[var(--wc-text-primary)]">添加联系人</span>
        </button>

        <div className="my-2 h-px bg-[var(--wc-border)]" />

        {/* Contact list */}
        <div className="min-h-0 flex-1 overflow-y-auto px-3 pb-3">
          {filtered.length === 0 ? (
            <p className="py-8 text-center text-[13px] text-[var(--wc-text-secondary)]">
              {search ? '无匹配联系人' : '暂无联系人，先添加一个'}
            </p>
          ) : (
            <ul>
              {filtered.map((p) => (
                <li key={p.projectId}>
                  <button
                    type="button"
                    onClick={() => onPickContact(p)}
                    className="flex w-full items-center gap-3 rounded-md px-2 py-2 text-left hover:bg-[var(--wc-item-hover)]"
                  >
                    <WeChatAvatar seed={p.projectId} title={p.displayName ?? '?'} size={36} />
                    <div className="flex min-w-0 flex-col">
                      <span className="truncate text-[13px] text-[var(--wc-text-primary)]">
                        {p.displayName ?? p.fullPath}
                      </span>
                      <span className="truncate text-[11px] text-[var(--wc-text-secondary)]">
                        {p.fullPath ?? p.path ?? ''}
                      </span>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
