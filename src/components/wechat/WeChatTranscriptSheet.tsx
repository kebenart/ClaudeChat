import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { X, Loader2, ChevronRight, Wrench } from 'lucide-react';

import { fetchTranscript, type TranscriptEntry } from '../../services/im/api';

// MARK: - WeChatTranscriptSheet
//
// "查看完整记录" — the raw, un-distilled session transcript (tools, thinking,
// tool results) that the IM chat stream intentionally hides. Paginated:
// loads the first page from the top, and scroll-up loads older entries via the
// first entry's id as the anchor. Big blobs are summarized; full payload fetch
// is a follow-up.
//
// Tool activity (tool_use / tool_result / thinking) is FOLDED: runs of
// consecutive tool entries collapse into a gray "执行了 N 个操作" bar that
// expands on click — same idea as the distilled stream, but here you can still
// drill into the raw payload.

interface Props {
  conversationId: string;
  title: string;
  onClose: () => void;
}

const PAGE = 40;
const FOLDABLE = new Set(['tool_use', 'tool_result', 'thinking']);

type RenderItem =
  | { kind: 'entry'; entry: TranscriptEntry }
  | { kind: 'toolgroup'; id: string; entries: TranscriptEntry[] };

/** Collapse consecutive tool/thinking entries into a single foldable group.
 *  Empty-summary `meta` rows (last-prompt / mode / attachment / snapshot — pure
 *  plumbing) are dropped so the count reflects real operations only. */
function buildRenderItems(entries: TranscriptEntry[]): RenderItem[] {
  const items: RenderItem[] = [];
  let run: TranscriptEntry[] = [];
  const flush = () => {
    if (run.length === 0) return;
    items.push({ kind: 'toolgroup', id: `tg-${run[0].id}`, entries: run });
    run = [];
  };
  for (const e of entries) {
    // Drop content-free plumbing entries entirely.
    if (e.kind === 'meta' && !e.summary.trim()) continue;
    if (e.kind && FOLDABLE.has(e.kind)) {
      run.push(e);
    } else {
      flush();
      items.push({ kind: 'entry', entry: e });
    }
  }
  flush();
  return items;
}

function EntryRow({ entry }: { entry: TranscriptEntry }) {
  const isUser = entry.role === 'user';
  return (
    <li className="rounded border border-[var(--wc-border)] px-3 py-2">
      <div className="mb-0.5 flex items-center gap-2">
        <span className="rounded bg-[var(--wc-item-hover)] px-1.5 py-0.5 text-[10px] uppercase text-[var(--wc-text-secondary)]">
          {isUser ? '我' : entry.role === 'assistant' ? 'Claude' : entry.type}
        </span>
        {entry.hasBlob && <span className="text-[10px] text-amber-600 dark:text-amber-500">大内容已截断</span>}
      </div>
      <pre className="whitespace-pre-wrap break-words text-[12px] text-[var(--wc-text-primary)]">
        {entry.summary}
      </pre>
    </li>
  );
}

function ToolGroup({ entries }: { entries: TranscriptEntry[] }) {
  const [open, setOpen] = useState(false);
  return (
    <li>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-2 rounded bg-[var(--wc-item-hover)] px-3 py-1.5 text-left text-[12px] text-[var(--wc-text-secondary)] transition-colors hover:brightness-95"
      >
        <Wrench className="h-3.5 w-3.5 shrink-0" />
        <span className="flex-1">执行了 {entries.length} 个操作</span>
        <ChevronRight className={`h-3.5 w-3.5 shrink-0 transition-transform ${open ? 'rotate-90' : ''}`} />
      </button>
      {open && (
        <ul className="mt-1 space-y-1 border-l-2 border-[var(--wc-border)] pl-3">
          {entries.map((e) => (
            <li key={e.id} className="rounded border border-[var(--wc-border)] px-2.5 py-1.5">
              <div className="mb-0.5 flex items-center gap-2">
                <span className="rounded bg-[var(--wc-item-hover)] px-1.5 py-0.5 text-[10px] uppercase text-[var(--wc-text-secondary)]">
                  {e.kind ?? e.type}
                </span>
                {e.hasBlob && <span className="text-[10px] text-amber-600 dark:text-amber-500">大内容已截断</span>}
              </div>
              <pre className="whitespace-pre-wrap break-words text-[12px] text-[var(--wc-text-secondary)]">
                {e.summary}
              </pre>
            </li>
          ))}
        </ul>
      )}
    </li>
  );
}

export default function WeChatTranscriptSheet({ conversationId, title, onClose }: Props) {
  const [entries, setEntries] = useState<TranscriptEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [hasMoreBefore, setHasMoreBefore] = useState(false);

  const scrollerRef = useRef<HTMLDivElement | null>(null);

  // Initial page = the LATEST entries (newest at the bottom, like a chat);
  // scrolling up loads older. Then jump to the bottom so the most recent
  // activity is visible immediately.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    void (async () => {
      try {
        const page = await fetchTranscript(conversationId, { numBefore: PAGE, numAfter: 0 });
        if (cancelled) return;
        setEntries(page.entries);
        setHasMoreBefore(page.hasMoreBefore);
        // After paint, scroll to the bottom (newest).
        requestAnimationFrame(() => {
          const el = scrollerRef.current;
          if (el) el.scrollTop = el.scrollHeight;
        });
      } catch (err) {
        if (!cancelled) console.error('[WeChatTranscriptSheet] load failed', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [conversationId]);

  const loadOlder = useCallback(async () => {
    if (!entries.length || loading) return;
    setLoading(true);
    try {
      const page = await fetchTranscript(conversationId, {
        anchor: entries[0].id,
        numBefore: PAGE,
        numAfter: 0,
      });
      setEntries((prev) => [...page.entries, ...prev]);
      setHasMoreBefore(page.hasMoreBefore);
    } catch (err) {
      console.error('[WeChatTranscriptSheet] load older failed', err);
    } finally {
      setLoading(false);
    }
  }, [conversationId, entries, loading]);

  const renderItems = useMemo(() => buildRenderItems(entries), [entries]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="flex max-h-[80vh] w-full max-w-2xl flex-col rounded-lg bg-[var(--wc-bg-app)] shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--wc-border)] px-4 py-3">
          <span className="truncate text-[14px] font-medium text-[var(--wc-text-primary)]">
            完整记录 · {title}
          </span>
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            aria-label="关闭"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div ref={scrollerRef} className="flex-1 overflow-y-auto overscroll-contain px-4 py-3">
          {hasMoreBefore && (
            <button
              type="button"
              onClick={() => void loadOlder()}
              disabled={loading}
              className="mb-2 w-full rounded border border-[var(--wc-border)] py-1.5 text-[12px] text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)] disabled:opacity-50"
            >
              加载更早
            </button>
          )}
          {loading && entries.length === 0 ? (
            <div className="flex items-center justify-center py-10 text-[var(--wc-text-secondary)]">
              <Loader2 className="h-5 w-5 animate-spin" />
            </div>
          ) : entries.length === 0 ? (
            <p className="py-10 text-center text-[13px] text-[var(--wc-text-secondary)]">暂无记录</p>
          ) : (
            <ul className="space-y-2">
              {renderItems.map((item) =>
                item.kind === 'entry' ? (
                  <EntryRow key={item.entry.id} entry={item.entry} />
                ) : (
                  <ToolGroup key={item.id} entries={item.entries} />
                ),
              )}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
