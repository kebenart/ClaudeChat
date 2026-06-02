import { memo, useMemo, useRef, useState } from 'react';
import { ChevronDown } from 'lucide-react';

import WeChatAvatar from './WeChatAvatar';
import WeChatMessageBubble, {
  WeChatMessageFullSheet,
  type WeChatMessage,
} from './WeChatMessageBubble';

// MARK: - WeChatMessageList
//
// 1:1 port of `ChatView.swift::messagesArea` + the `renderItems` time-divider
// pass + the `ToolBatchView` collapsible card.

interface Props {
  messages: WeChatMessage[];
  /** True when a stream_delta is still being received and we should show the
   *  3-dot indicator at the very bottom. */
  isStreaming?: boolean;
  /** Approve / reject a pending tool call by request id. */
  onApprove?: (requestId: string) => void;
  onReject?: (requestId: string) => void;
  onQuote?: (content: string) => void;
  /** Resend a failed outgoing message by its (stable) message id. */
  onResend?: (messageId: string) => void;
  /** Submit an AskUserQuestion choice card answer. */
  onChoiceAnswer?: (requestId: string, answers: Record<string, string[]>) => void;
  /** Approve / reject an ExitPlanMode choice card. */
  onChoicePlan?: (requestId: string, approve: boolean) => void;
  /** Initial number of messages to keep rendered. Larger sessions are
   *  windowed — older messages are kept in memory but not in the DOM until
   *  the user clicks "加载更早". Default 200 matches macOS displayLimit. */
  initialWindow?: number;
  /** Avatar seed/title for incoming (Claude/tool) bubbles — set to the
   *  conversation id so the chat avatar matches the sidebar row. */
  contactSeed?: string;
  contactTitle?: string;
}

const TIME_GROUP_THRESHOLD_MS = 5 * 60 * 1000;

function formatTimeGroup(date: Date): string {
  const now = new Date();
  const sameDay =
    now.getFullYear() === date.getFullYear() &&
    now.getMonth() === date.getMonth() &&
    now.getDate() === date.getDate();
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  const isYesterday =
    yesterday.getFullYear() === date.getFullYear() &&
    yesterday.getMonth() === date.getMonth() &&
    yesterday.getDate() === date.getDate();
  const hh = String(date.getHours()).padStart(2, '0');
  const mm = String(date.getMinutes()).padStart(2, '0');
  const time = `${hh}:${mm}`;
  if (sameDay) return time;
  if (isYesterday) return `昨天 ${time}`;
  const diffDays = Math.floor((now.getTime() - date.getTime()) / (24 * 60 * 60 * 1000));
  if (diffDays >= 0 && diffDays < 7) {
    const wd = ['日', '一', '二', '三', '四', '五', '六'][date.getDay()];
    return `周${wd} ${time}`;
  }
  const yyyy = date.getFullYear();
  const MM = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return `${yyyy}-${MM}-${dd} ${time}`;
}

interface MessageItem {
  kind: 'message';
  id: string;
  msg: WeChatMessage;
}
interface ToolRunItem {
  kind: 'toolRun';
  id: string;
  count: number;
}
interface DividerItem {
  kind: 'time';
  id: string;
  label: string;
}
type RenderItem = MessageItem | ToolRunItem | DividerItem;

// A "plain" tool message is a pure tool_use/tool_result row (no interactive
// approval affordance). These are collapsed into a single "执行了 N 个操作"
// count line — the full detail stays reachable via the transcript sheet.
// Permission rows (requiresApproval / pending requestId) are NOT collapsed:
// they're interactive approval prompts the user must act on.
function isPlainTool(m: WeChatMessage): boolean {
  return m.role === 'tool' && !m.tool?.requiresApproval;
}

function buildRenderItems(messages: WeChatMessage[]): RenderItem[] {
  const out: RenderItem[] = [];
  let prevTs: Date | null = null;
  let runStart: WeChatMessage | null = null;
  let runCount = 0;

  const flushRun = () => {
    if (runCount === 0 || !runStart) return;
    out.push({ kind: 'toolRun', id: `run-${runStart.id}`, count: runCount });
    runStart = null;
    runCount = 0;
  };

  for (const m of messages) {
    if (isPlainTool(m)) {
      if (!runStart) runStart = m;
      runCount += 1;
      continue;
    }
    flushRun();
    if (
      m.role !== 'tool' &&
      (!prevTs ||
        m.createdAt.getTime() - prevTs.getTime() > TIME_GROUP_THRESHOLD_MS)
    ) {
      out.push({
        kind: 'time',
        id: `ts-${m.id}`,
        label: formatTimeGroup(m.createdAt),
      });
    }
    if (m.role !== 'tool') prevTs = m.createdAt;
    out.push({ kind: 'message', id: m.id, msg: m });
  }
  flushRun();
  return out;
}

// ────────────────────────────────────────────────────────────────────────────
// Tool run (collapsed count line)
// ────────────────────────────────────────────────────────────────────────────
//
// A maximal run of consecutive plain tool messages is rendered as ONE compact,
// non-expandable muted line — "⚙️ 执行了 N 个操作". The full tool input/output
// is intentionally not rendered inline; it stays reachable via the header's
// "查看完整记录" transcript button.

function ToolRunLine({ count }: { count: number }) {
  return (
    <div className="flex items-center justify-center py-0.5">
      <span className="text-[11px] text-[var(--wc-text-secondary)]">
        ⚙️ 执行了 {count} 个操作
      </span>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────────────
// MessageList
// ────────────────────────────────────────────────────────────────────────────

function WeChatMessageList({
  messages,
  isStreaming,
  onApprove,
  onReject,
  onQuote,
  onResend,
  onChoiceAnswer,
  onChoicePlan,
  initialWindow = 200,
  contactSeed,
  contactTitle,
}: Props) {
  const [displayLimit, setDisplayLimit] = useState(initialWindow);
  // When a new message arrives, grow the window so it's visible without
  // forcing a click. Mirror macOS ChatViewModel.bump behaviour.
  const lastCount = useRef(messages.length);
  if (messages.length > lastCount.current) {
    if (messages.length > displayLimit) {
      setDisplayLimit(messages.length);
    }
    lastCount.current = messages.length;
  }
  // When the session changes (messages array shrinks back to a new history),
  // reset the window.
  if (messages.length < lastCount.current) {
    lastCount.current = messages.length;
    if (displayLimit !== initialWindow) {
      setDisplayLimit(initialWindow);
    }
  }

  const visible = useMemo(
    () => messages.slice(Math.max(0, messages.length - displayLimit)),
    [messages, displayLimit],
  );
  const hiddenOlderCount = messages.length - visible.length;
  const items = useMemo(() => buildRenderItems(visible), [visible]);
  const [fullSheetMsg, setFullSheetMsg] = useState<WeChatMessage | null>(null);

  const loadMore = () => {
    setDisplayLimit((cur) => Math.min(messages.length, cur + 200));
  };

  return (
    <div className="flex min-w-0 flex-col gap-3.5 overflow-x-hidden px-4 py-3.5">
      {hiddenOlderCount > 0 && (
        <div className="flex justify-center py-1">
          <button
            type="button"
            onClick={loadMore}
            className="inline-flex items-center gap-1 rounded-full border border-zinc-200 bg-white px-3 py-1 text-[11px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
          >
            <ChevronDown className="h-3 w-3 -rotate-90" />
            加载更早 {Math.min(200, hiddenOlderCount)} 条 (还剩 {hiddenOlderCount})
          </button>
        </div>
      )}
      {items.map((item) => {
        if (item.kind === 'time') {
          return (
            <div key={item.id} className="flex items-center justify-center py-1">
              <span className="rounded-full bg-zinc-200/60 px-2 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-700/60 dark:text-zinc-400">
                {item.label}
              </span>
            </div>
          );
        }
        if (item.kind === 'toolRun') {
          return <ToolRunLine key={item.id} count={item.count} />;
        }
        const m = item.msg;
        return (
          <WeChatMessageBubble
            key={item.id}
            message={m}
            contactSeed={contactSeed}
            contactTitle={contactTitle}
            onApprove={
              m.tool?.requiresApproval && m.tool.requestId
                ? () => onApprove?.(m.tool!.requestId!)
                : undefined
            }
            onReject={
              m.tool?.requiresApproval && m.tool.requestId
                ? () => onReject?.(m.tool!.requestId!)
                : undefined
            }
            onQuote={onQuote}
            onResend={onResend ? () => onResend(m.id) : undefined}
            onChoiceAnswer={onChoiceAnswer}
            onChoicePlan={onChoicePlan}
            onOpenFull={(msg) => setFullSheetMsg(msg)}
          />
        );
      })}

      {/* Streaming indicator */}
      {isStreaming && (
        <div className="flex items-start gap-2">
          <WeChatAvatar seed={contactSeed ?? 'claude-assistant'} title={contactTitle ?? 'C'} size={40} />
          <div className="inline-flex items-center gap-1 rounded-[4px] bg-white px-3 py-2.5 shadow-[0_1px_0_rgba(0,0,0,0.04)] dark:bg-zinc-100">
            <span className="block h-1.5 w-1.5 animate-pulse rounded-full bg-zinc-400 [animation-delay:0ms]" />
            <span className="block h-1.5 w-1.5 animate-pulse rounded-full bg-zinc-400 [animation-delay:200ms]" />
            <span className="block h-1.5 w-1.5 animate-pulse rounded-full bg-zinc-400 [animation-delay:400ms]" />
          </div>
          <div className="flex-1" />
        </div>
      )}

      {fullSheetMsg && (
        <WeChatMessageFullSheet
          message={fullSheetMsg}
          onClose={() => setFullSheetMsg(null)}
        />
      )}
    </div>
  );
}

// Wrapped in React.memo so the parent (WeChatChatPane) re-rendering on every
// composer keystroke (the `draft` state lives there) does NOT re-render the
// whole — potentially long — message list. All props passed by the parent are
// referentially stable across keystrokes: `messages` only changes on a real
// message update, and every callback is useCallback-memoized there. The list
// receives nothing that changes when `draft` changes.
export default memo(WeChatMessageList);
