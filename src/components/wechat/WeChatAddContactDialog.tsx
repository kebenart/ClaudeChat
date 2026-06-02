import { useState } from 'react';
import { Loader2, X } from 'lucide-react';

import { api } from '../../utils/api';

// MARK: - WeChatAddContactDialog
//
// Lightweight, WeChat-styled "添加联系人" — a contact is a working directory
// (project). Enter an absolute path on the server machine (and an optional
// display name) and it's registered via POST /api/projects/create-project.
// Replaces the heavier multi-step ProjectCreationWizard so the styling stays
// consistent with the rest of the IM shell.

interface Props {
  onClose: () => void;
  onCreated: () => void;
}

export default function WeChatAddContactDialog({ onClose, onCreated }: Props) {
  const [path, setPath] = useState('');
  const [name, setName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = path.trim();
    if (!trimmed) {
      setError('请输入工作目录的绝对路径');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const res = await api.createProject({ path: trimmed, customName: name.trim() || undefined });
      // The API returns errors as a structured object ({ code, message, details })
      // and may use HTTP 200 with `success:false`, so unwrap both carefully.
      const data = (await res.json().catch(() => ({}))) as {
        success?: boolean;
        error?: string | { message?: string; details?: string };
        message?: string;
      };
      if (!res.ok || data.success === false) {
        const e = data.error;
        const msg =
          typeof e === 'string'
            ? e
            : e?.details || e?.message || data.message || `创建失败 (${res.status})`;
        throw new Error(msg);
      }
      onCreated();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : '创建失败');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="flex w-full max-w-md flex-col overflow-hidden rounded-lg bg-[var(--wc-bg-app)] shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--wc-border)] px-4 py-3">
          <span className="text-[14px] font-medium text-[var(--wc-text-primary)]">添加联系人</span>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            aria-label="关闭"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex flex-col gap-3 px-4 py-4">
          <label className="flex flex-col gap-1">
            <span className="text-[12px] text-[var(--wc-text-secondary)]">工作目录(绝对路径)</span>
            <input
              type="text"
              value={path}
              onChange={(e) => setPath(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void submit();
              }}
              placeholder="/Users/you/code/my-project"
              autoFocus
              spellCheck={false}
              autoCorrect="off"
              className="rounded-[6px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] px-2.5 py-2 text-[13px] text-[var(--wc-text-primary)] outline-none placeholder:text-[var(--wc-text-secondary)] focus:border-[var(--wc-accent)]"
            />
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-[12px] text-[var(--wc-text-secondary)]">备注名(可选)</span>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void submit();
              }}
              placeholder="留空则用文件夹名"
              className="rounded-[6px] border border-[var(--wc-border)] bg-[var(--wc-bg-search)] px-2.5 py-2 text-[13px] text-[var(--wc-text-primary)] outline-none placeholder:text-[var(--wc-text-secondary)] focus:border-[var(--wc-accent)]"
            />
          </label>

          {error && <p className="text-[12px] text-[var(--wc-badge)]">{error}</p>}
        </div>

        <div className="flex justify-end gap-2 border-t border-[var(--wc-border)] px-4 py-3">
          <button
            type="button"
            onClick={onClose}
            className="rounded-[6px] px-3 py-1.5 text-[13px] text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
          >
            取消
          </button>
          <button
            type="button"
            onClick={() => void submit()}
            disabled={submitting}
            className="inline-flex items-center gap-1.5 rounded-[6px] bg-[var(--wc-accent)] px-3 py-1.5 text-[13px] font-medium text-white hover:opacity-90 disabled:opacity-50"
          >
            {submitting && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
            添加
          </button>
        </div>
      </div>
    </div>
  );
}
