import { useEffect, useMemo, useRef, useState } from 'react';
import { Check, CheckCheck, Copy, Quote, Loader2, AlertTriangle, RefreshCw, X } from 'lucide-react';

import { Markdown } from '../chat/view/subcomponents/Markdown';
import { useAuth } from '../auth';
import { fetchMessageContent } from '../../services/im/api';
import type { ChoiceCardContent, ImageCardContent } from '../../services/im/protocol';

import WeChatAvatar from './WeChatAvatar';
import WeChatToolCard, { type WeChatToolPayload } from './WeChatToolCard';
import WeChatChoiceCard from './WeChatChoiceCard';
import WeChatImageBubble from './WeChatImageBubble';

// MARK: - WeChatMessageBubble
//
// 1:1 port of `Sources/ChatKit/UI/Chat/MessageBubble.swift`.
//
// Bubble shape:
//   - User (outgoing): right-aligned, `bg-[#95ec69]` with black text.
//   - Claude (incoming): left-aligned, white with black text + left-pointing
//     triangle tail.
//   - Tool: a separate ToolCard component, always left-aligned.
//
// Length tiers (matches MessageTextTier in Swift):
//   - `< 500 chars` AND no markdown structure → render inline, full content.
//   - otherwise → truncated preview clipped to ~140px with gradient fade +
//     "双击查看完整 (N 字符)" footer. Double-clicking opens a sheet.
//
// Markdown rendering mirrors `MessageBubble.swift::lineView`: line-by-line,
// recognises `#`/`##`/`###`, `-`/`*` bullets, `\d+.` ordered lists, `>`
// blockquotes. Code blocks → CodeBlockView.
//
// Status indicators (left of user bubble): sending → spinner; sent → ✓;
// delivered → ✓✓; failed → red ❗ (clickable to view the reason).
//
// Right-click → 引用 / 复制 / (failed) 查看失败原因.

export type WeChatMessageRole = 'user' | 'assistant' | 'tool' | 'system';
export type WeChatSendStatus = 'sending' | 'sent' | 'delivered' | 'failed';

export interface WeChatMessage {
  id: string;
  role: WeChatMessageRole;
  content: string;
  createdAt: Date;
  /** IM hub seq for this distilled message. Used to anchor "load older
   *  history" fetches at the top of the chat (oldest loaded seq). Absent on
   *  optimistic/streamed bubbles that the IM stream doesn't know about yet. */
  seq?: number;
  /** Conversation this message belongs to — needed to lazy-fetch the full body
   *  of a server-truncated message. Set on distilled history rows. */
  conversationId?: string;
  /** Server P2 long-message truncation: when true, `content` is only the first
   *  800 chars and the full text must be fetched on demand via
   *  fetchMessageContent(conversationId, id). */
  truncated?: boolean;
  /** Total length of the full (un-truncated) body. Only set when truncated. */
  fullLength?: number;
  sendStatus?: WeChatSendStatus;
  sendError?: string;
  /** Tool payload — only meaningful when role === 'tool'. */
  tool?: WeChatToolPayload;
  /** Parsed interactive choice card — set when the wire message had
   *  kind === 'choice' and the JSON content parsed cleanly. Rendered as a
   *  红包-style card that opens a poll modal. */
  choice?: ChoiceCardContent;
  /** Parsed assistant-sent image — set when the wire message had kind ===
   *  'image'. Rendered as an image bubble (bytes fetched from /api/im/media). */
  image?: ImageCardContent;
  /** Whether this assistant bubble is still receiving stream_delta frames. */
  isStreaming?: boolean;
  /** Snapshot of the wire payload captured at first send so a failed outgoing
   *  bubble can be re-sent verbatim (text already composed with quote/file
   *  refs, plus any images). Only set on optimistic user messages. */
  resend?: {
    text: string;
    images?: { data: string; name: string }[];
  };
}

interface Props {
  message: WeChatMessage;
  onApprove?: () => void;
  onReject?: () => void;
  onQuote?: (content: string) => void;
  /** Resend this (failed) outgoing message — flips it back to 'sending' and
   *  re-runs the original send path. Only wired for failed user bubbles. */
  onResend?: () => void;
  /** Open the "full content" sheet (the parent owns the dialog). */
  onOpenFull?: (message: WeChatMessage) => void;
  /** Submit an AskUserQuestion answer for a choice card. `answers` maps each
   *  question text → the selected option labels. */
  onChoiceAnswer?: (requestId: string, answers: Record<string, string[]>) => void;
  /** Approve / reject an ExitPlanMode choice card. */
  onChoicePlan?: (requestId: string, approve: boolean) => void;
  /** Avatar seed/title for the incoming (Claude/tool) side — set to the
   *  conversation id so it matches the sidebar row's avatar. */
  contactSeed?: string;
  contactTitle?: string;
}

// Cap the bubble width responsively. Desktop: 520px; mobile: 80vw to avoid
// horizontal overflow. Applied via Tailwind arbitrary value so we don't need
// a media query in JS.
const BUBBLE_MAX_W_CLASS = 'max-w-[min(80vw,520px)]';
const TRUNCATE_THRESHOLD = 500;
const TRUNCATE_MAX_HEIGHT = 140;

// ────────────────────────────────────────────────────────────────────────────
// Markdown / code-block segmentation (mirrors Swift's parseMarkdownSegments)
// ────────────────────────────────────────────────────────────────────────────

interface TextSegment {
  type: 'text';
  value: string;
}

interface CodeSegment {
  type: 'code';
  language: string | null;
  value: string;
}

type Segment = TextSegment | CodeSegment;

function parseSegments(raw: string): Segment[] {
  const out: Segment[] = [];
  const lines = raw.split('\n');
  let i = 0;
  let buf: string[] = [];
  const flushText = () => {
    if (buf.length === 0) return;
    out.push({ type: 'text', value: buf.join('\n') });
    buf = [];
  };
  while (i < lines.length) {
    const line = lines[i];
    const fenceMatch = /^\s*```([a-zA-Z0-9_+-]*)\s*$/.exec(line);
    if (fenceMatch) {
      flushText();
      const language = fenceMatch[1] || null;
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) {
        code.push(lines[i]);
        i += 1;
      }
      // skip closing fence
      if (i < lines.length) i += 1;
      out.push({ type: 'code', language, value: code.join('\n') });
      continue;
    }
    buf.push(line);
    i += 1;
  }
  flushText();
  return out;
}

function hasHeadingsOrLists(text: string): boolean {
  for (const raw of text.split('\n')) {
    const trimmed = raw.replace(/^\s+/, '');
    if (
      trimmed.startsWith('# ') ||
      trimmed.startsWith('## ') ||
      trimmed.startsWith('### ') ||
      trimmed.startsWith('- ') ||
      trimmed.startsWith('* ') ||
      trimmed.startsWith('> ')
    ) {
      return true;
    }
    if (/^\d+\.\s/.test(trimmed)) return true;
  }
  return false;
}

// Cheap inline markdown: **bold**, *italic*, `code`, [link](url).
// Mirrors the AttributedString(markdown:) Swift uses for one-line text.
function renderInline(line: string): React.ReactNode[] {
  const parts: React.ReactNode[] = [];
  // Use a manual scanner — keep ordering stable & avoid regex backtracking.
  let rest = line;
  let key = 0;
  const push = (node: React.ReactNode) => {
    parts.push(<span key={`s-${key++}`}>{node}</span>);
  };
  while (rest.length > 0) {
    // bold (**...**)
    const bold = /^\*\*([^*]+)\*\*/.exec(rest);
    if (bold) {
      push(<strong className="font-semibold">{bold[1]}</strong>);
      rest = rest.slice(bold[0].length);
      continue;
    }
    // inline code (`...`)
    const code = /^`([^`]+)`/.exec(rest);
    if (code) {
      push(
        <code className="rounded bg-zinc-200/70 px-1 py-px font-mono text-[0.92em] text-zinc-800 dark:bg-zinc-700/70 dark:text-zinc-200">
          {code[1]}
        </code>,
      );
      rest = rest.slice(code[0].length);
      continue;
    }
    // italic (*...*)  — only when bold didn't match
    const italic = /^\*([^*]+)\*/.exec(rest);
    if (italic) {
      push(<em className="italic">{italic[1]}</em>);
      rest = rest.slice(italic[0].length);
      continue;
    }
    // link [text](url)
    const link = /^\[([^\]]+)\]\(([^)]+)\)/.exec(rest);
    if (link) {
      push(
        <a
          href={link[2]}
          target="_blank"
          rel="noreferrer"
          className="text-[var(--wc-link)] underline-offset-2 hover:underline"
        >
          {link[1]}
        </a>,
      );
      rest = rest.slice(link[0].length);
      continue;
    }
    // No match — consume one char.
    push(rest[0]);
    rest = rest.slice(1);
  }
  return parts;
}

// Render a multi-line markdown text segment.
function MarkdownLines({ raw }: { raw: string }) {
  const lines = raw.split('\n');
  return (
    <div className="flex flex-col gap-[3px]">
      {lines.map((line, idx) => {
        const trimmed = line.replace(/^\s+/, '');
        if (trimmed.startsWith('### ')) {
          return (
            <div key={idx} className="pt-0.5 text-[14px] font-semibold">
              {renderInline(trimmed.slice(4))}
            </div>
          );
        }
        if (trimmed.startsWith('## ')) {
          return (
            <div key={idx} className="pt-0.5 text-[15px] font-semibold">
              {renderInline(trimmed.slice(3))}
            </div>
          );
        }
        if (trimmed.startsWith('# ')) {
          return (
            <div key={idx} className="pt-0.5 text-[17px] font-bold">
              {renderInline(trimmed.slice(2))}
            </div>
          );
        }
        if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
          return (
            <div key={idx} className="flex items-baseline gap-1.5">
              <span className="opacity-70">•</span>
              <span>{renderInline(trimmed.slice(2))}</span>
            </div>
          );
        }
        const ordered = /^(\d+\.\s)(.*)$/.exec(trimmed);
        if (ordered) {
          return (
            <div key={idx} className="flex items-baseline gap-1.5">
              <span className="opacity-70">{ordered[1].trim()}</span>
              <span>{renderInline(ordered[2])}</span>
            </div>
          );
        }
        if (trimmed.startsWith('> ')) {
          return (
            <div key={idx} className="flex items-start gap-2 pl-0.5">
              <span className="block w-[3px] self-stretch bg-current opacity-30" />
              <span className="opacity-85">{renderInline(trimmed.slice(2))}</span>
            </div>
          );
        }
        if (line === '') {
          return <div key={idx} className="h-1" />;
        }
        return (
          <div key={idx} className="whitespace-pre-wrap break-words">
            {renderInline(line)}
          </div>
        );
      })}
    </div>
  );
}

// Render a fenced code block. No external highlighter — uses a plain <pre> so
// we don't pull in extra dependencies for v0 (matches Swift's CodeBlockView
// minimal styling).
function CodeBlock({ language, value }: CodeSegment) {
  return (
    <div className="overflow-hidden rounded border border-zinc-200 bg-[#f6f6f6] dark:border-zinc-700 dark:bg-zinc-800">
      {language && (
        <div className="border-b border-zinc-200 bg-white/60 px-2 py-1 font-mono text-[10px] uppercase tracking-wider text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900/60 dark:text-zinc-400">
          {language}
        </div>
      )}
      <pre className="overflow-auto whitespace-pre p-2 font-mono text-[12px] leading-snug text-zinc-800 dark:text-zinc-200">
        {value}
      </pre>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Context menu
// ────────────────────────────────────────────────────────────────────────────

interface MenuState {
  open: boolean;
  x: number;
  y: number;
}

function useContextMenu() {
  const [state, setState] = useState<MenuState>({ open: false, x: 0, y: 0 });
  useEffect(() => {
    if (!state.open) return;
    const close = () => setState((s) => ({ ...s, open: false }));
    window.addEventListener('click', close);
    window.addEventListener('scroll', close, true);
    window.addEventListener('keydown', close);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('scroll', close, true);
      window.removeEventListener('keydown', close);
    };
  }, [state.open]);
  return { state, setState };
}

// ────────────────────────────────────────────────────────────────────────────
// Component
// ────────────────────────────────────────────────────────────────────────────

export default function WeChatMessageBubble({
  message,
  onApprove,
  onReject,
  onQuote,
  onResend,
  onOpenFull,
  onChoiceAnswer,
  onChoicePlan,
  contactSeed,
  contactTitle,
}: Props) {
  const incomingSeed = contactSeed ?? 'claude-assistant';
  const incomingTitle = contactTitle ?? 'C';
  // Self avatar — same seed as the 我 tab so they always match.
  const { user } = useAuth();
  const selfSeed = user?.username ? `user-${user.username}` : 'me';
  const selfTitle = user?.username ?? 'Me';
  const isUser = message.role === 'user';
  const isTool = message.role === 'tool';
  const [showErrorPopover, setShowErrorPopover] = useState(false);
  const { state: menu, setState: setMenu } = useContextMenu();
  const popoverRef = useRef<HTMLDivElement | null>(null);
  const rawText = message.content ?? '';
  const segments = useMemo(() => parseSegments(rawText), [rawText]);

  // Assistant-sent image (kind:'image') — incoming (left) image bubble.
  if (message.image) {
    return (
      <div className="flex items-start gap-2">
        <WeChatAvatar seed={incomingSeed} title={incomingTitle} size={40} />
        <WeChatImageBubble image={message.image} />
        <div className="flex-1" />
      </div>
    );
  }

  // Interactive choice cards (AskUserQuestion / ExitPlanMode) render a
  // 红包-style card on the incoming (left) side, same column as tool cards.
  if (message.choice) {
    return (
      <div className="flex items-start gap-2">
        <WeChatAvatar seed={incomingSeed} title={incomingTitle} size={40} />
        <WeChatChoiceCard
          card={message.choice}
          onAnswer={onChoiceAnswer}
          onPlan={onChoicePlan}
        />
        <div className="flex-1" />
      </div>
    );
  }

  // Tool messages render an entirely different layout.
  if (isTool && message.tool) {
    return (
      <div className="flex items-start gap-2">
        <WeChatAvatar seed={incomingSeed} title={incomingTitle} size={40} />
        <WeChatToolCard
          payload={message.tool}
          onApprove={onApprove}
          onReject={onReject}
        />
        <div className="flex-1" />
      </div>
    );
  }
  const hasOnlyText = segments.every((s) => s.type === 'text');
  const isLong = rawText.length >= TRUNCATE_THRESHOLD;
  // Server-side truncation (Server P2): `content` holds only the first 800
  // chars; the full body is lazy-fetched in the sheet. Always render as a
  // preview with a "查看全文" footer regardless of the local length heuristics.
  const isServerTruncated = message.truncated === true;
  const needsTruncation = isServerTruncated || !hasOnlyText || hasHeadingsOrLists(rawText) || isLong;

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    setMenu({ open: true, x: e.clientX, y: e.clientY });
  };

  const handleCopy = () => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      void navigator.clipboard.writeText(rawText);
    }
    setMenu((s) => ({ ...s, open: false }));
  };
  const handleQuote = () => {
    onQuote?.(rawText);
    setMenu((s) => ({ ...s, open: false }));
  };

  // Bubble inner content (either plain or truncated)
  const bubbleClasses = [
    'relative inline-block rounded-[4px] px-3 py-2 text-[13px]',
    isUser
      ? 'bg-[var(--wc-msg-out)] text-[var(--wc-msg-out-text)]'
      : 'bg-[var(--wc-msg-in)] text-[var(--wc-msg-in-text)]',
    'shadow-[0_1px_0_rgba(0,0,0,0.04)]',
  ].join(' ');

  const fullContent = (
    <>
      {segments.map((seg, idx) => {
        if (seg.type === 'code') {
          return <CodeBlock key={idx} {...seg} />;
        }
        return <MarkdownLines key={idx} raw={seg.value} />;
      })}
    </>
  );

  const openFull = () => onOpenFull?.(message);

  const truncatedContent = (
    <div
      className="relative overflow-hidden"
      style={{ maxHeight: TRUNCATE_MAX_HEIGHT }}
    >
      <div className="pb-7">
        <MarkdownLines raw={rawText.slice(0, TRUNCATE_THRESHOLD)} />
      </div>
      {/* Gradient fade — pointer-events-none so the button below stays tappable */}
      <div
        className="pointer-events-none absolute bottom-0 left-0 right-0 h-7"
        style={{
          background: `linear-gradient(to bottom, transparent 0%, ${
            isUser ? 'var(--wc-msg-out)' : 'var(--wc-msg-in)'
          } 100%)`,
        }}
      />
      {/* Footer hint — a real button so a single tap/click expands it on both
          desktop and mobile (double-tap is unreliable on touch). */}
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation();
          openFull();
        }}
        className="absolute bottom-0 left-0 right-0 z-10 py-1 text-center text-[10px] font-medium text-[var(--wc-link)] active:opacity-70"
      >
        {isServerTruncated
          ? `查看全文 (${message.fullLength ?? rawText.length} 字符)`
          : `点击查看完整 (${rawText.length} 字符)`}
      </button>
    </div>
  );

  const bubble = (
    <div
      className={`${bubbleClasses} ${BUBBLE_MAX_W_CLASS}`}
      onContextMenu={handleContextMenu}
      onDoubleClick={needsTruncation ? openFull : undefined}
      title={needsTruncation ? '点击底部按钮查看完整内容' : undefined}
    >
      <div className="flex flex-col gap-1.5 whitespace-pre-wrap break-words">
        {needsTruncation ? truncatedContent : fullContent}
      </div>
      {/* Bubble tail */}
      <span
        aria-hidden
        className="absolute top-[10px] block h-2 w-1.5"
        style={{
          [isUser ? 'right' : 'left']: -5,
          background: isUser ? 'var(--wc-msg-out)' : 'var(--wc-msg-in)',
          clipPath: isUser
            ? 'polygon(0 0, 100% 50%, 0 100%)'
            : 'polygon(100% 0, 0 50%, 100% 100%)',
        }}
      />
    </div>
  );

  // Status indicator
  const statusIndicator = (() => {
    if (!isUser) return null;
    switch (message.sendStatus) {
      case 'sending':
        return (
          <Loader2 className="mt-3 h-3 w-3 animate-spin text-zinc-400" />
        );
      case 'sent':
        return <Check className="mt-3 h-3 w-3 text-zinc-400" />;
      case 'delivered':
        return <CheckCheck className="mt-3 h-3 w-3 text-[var(--wc-accent)]" />;
      case 'failed':
        return (
          <button
            type="button"
            className="relative mt-2 inline-flex items-center justify-center rounded-full transition-transform hover:scale-110 active:scale-95"
            onClick={(e) => {
              e.stopPropagation();
              // Single tap/click resends when a resend handler is wired (the
              // normal case). Otherwise fall back to toggling the error popover
              // so the reason is still reachable.
              if (onResend) {
                onResend();
                return;
              }
              setShowErrorPopover((v) => !v);
            }}
            title={onResend ? '发送失败，点击重新发送' : '发送失败，点击查看原因'}
            aria-label={onResend ? '发送失败，点击重新发送' : '发送失败，点击查看原因'}
          >
            {/* Red circle with a white "!" — WeChat's failed-send affordance. */}
            <AlertTriangle className="h-3.5 w-3.5 fill-red-500 text-white" />
            {showErrorPopover && (
              <div
                ref={popoverRef}
                className="absolute right-full top-0 z-50 mr-2 w-[300px] rounded border border-zinc-200 bg-white p-3 text-left shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
              >
                <div className="mb-1 flex items-center gap-1.5 text-[13px] font-semibold text-red-500">
                  <AlertTriangle className="h-3.5 w-3.5" />
                  发送失败
                </div>
                <div className="text-[12px] text-zinc-700 dark:text-zinc-200">
                  {message.sendError ?? '未知原因。请检查网络或重新登录。'}
                </div>
                {onResend && (
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      setShowErrorPopover(false);
                      onResend();
                    }}
                    className="mt-2 inline-flex items-center gap-1 rounded bg-[var(--wc-accent)] px-2 py-1 text-[12px] font-medium text-white hover:opacity-90"
                  >
                    <RefreshCw className="h-3 w-3" /> 重新发送
                  </button>
                )}
              </div>
            )}
          </button>
        );
      default:
        return null;
    }
  })();

  return (
    <div className={['flex items-start gap-2', isUser ? 'justify-end' : 'justify-start'].join(' ')}>
      {!isUser && <WeChatAvatar seed={incomingSeed} title={incomingTitle} size={40} />}
      {isUser && <div className="flex-1" />}
      <div
        className={['flex items-start gap-1 min-w-0', isUser ? 'flex-row' : 'flex-row', BUBBLE_MAX_W_CLASS].join(' ')}
      >
        {isUser && statusIndicator}
        {bubble}
      </div>
      {isUser && <WeChatAvatar seed={selfSeed} title={selfTitle} size={40} />}
      {!isUser && <div className="flex-1" />}

      {/* Right-click context menu */}
      {menu.open && (
        <div
          className="fixed z-50 min-w-[140px] rounded-md border border-zinc-200 bg-white py-1 text-[13px] shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
          style={{ left: menu.x, top: menu.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {onQuote && (
            <button
              type="button"
              onClick={handleQuote}
              className="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              <Quote className="h-3.5 w-3.5" /> 引用
            </button>
          )}
          <button
            type="button"
            onClick={handleCopy}
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            <Copy className="h-3.5 w-3.5" /> 复制
          </button>
          {message.sendStatus === 'failed' && (
            <>
              <div className="my-1 border-t border-zinc-200 dark:border-zinc-700" />
              {onResend && (
                <button
                  type="button"
                  onClick={() => {
                    setMenu((s) => ({ ...s, open: false }));
                    onResend();
                  }}
                  className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-[var(--wc-accent)] hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  <RefreshCw className="h-3.5 w-3.5" /> 重新发送
                </button>
              )}
              <button
                type="button"
                onClick={() => {
                  setShowErrorPopover(true);
                  setMenu((s) => ({ ...s, open: false }));
                }}
                className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-red-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                <AlertTriangle className="h-3.5 w-3.5" /> 查看失败原因
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Full-content sheet (parent renders one of these when onOpenFull fires)
// ────────────────────────────────────────────────────────────────────────────

export function WeChatMessageFullSheet({
  message,
  onClose,
}: {
  message: WeChatMessage;
  onClose: () => void;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  // Server-truncated messages only carry the first 800 chars inline; fetch the
  // full body on open. Non-truncated messages already have everything in
  // `message.content`, so no round-trip.
  const needsFetch =
    message.truncated === true && Boolean(message.conversationId);
  const [fullText, setFullText] = useState<string | null>(
    needsFetch ? null : message.content,
  );
  const [loading, setLoading] = useState(needsFetch);
  const [fetchError, setFetchError] = useState<string | null>(null);

  useEffect(() => {
    if (!needsFetch || !message.conversationId) return;
    let cancelled = false;
    setLoading(true);
    setFetchError(null);
    void (async () => {
      try {
        const content = await fetchMessageContent(message.conversationId!, message.id);
        if (!cancelled) setFullText(content);
      } catch (err) {
        if (!cancelled) {
          console.error('[WeChatMessageFullSheet] full content fetch failed', err);
          setFetchError('加载全文失败，请重试');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [needsFetch, message.conversationId, message.id]);

  const charCount = message.truncated ? message.fullLength ?? message.content.length : message.content.length;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[80vh] w-full max-w-[760px] flex-col overflow-hidden rounded-lg border border-[var(--wc-border)] bg-[var(--wc-bg-app)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--wc-border)] px-4 py-2">
          <span className="text-[13px] font-medium text-[var(--wc-text-primary)]">
            {message.role === 'user' ? '我的消息' : 'Claude 回复'} ({charCount} 字符)
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
        {/* Full GFM markdown (tables, code highlighting, math, task lists) via
            the shared chat Markdown renderer — the inline bubble uses a lighter
            line-by-line renderer, but the popup gets the complete treatment. */}
        <div className="flex-1 overflow-auto px-4 py-3 text-[13px] text-[var(--wc-msg-in-text)]">
          {loading ? (
            <div className="flex items-center justify-center gap-2 py-8 text-[12px] text-[var(--wc-text-secondary)]">
              <Loader2 className="h-4 w-4 animate-spin" />
              加载全文…
            </div>
          ) : fetchError ? (
            <div className="flex flex-col items-center gap-2 py-8 text-[12px] text-[var(--wc-text-secondary)]">
              <AlertTriangle className="h-4 w-4 text-red-500" />
              {fetchError}
              {/* Fall back to the truncated preview we already have. */}
              <div className="mt-2 w-full text-[var(--wc-msg-in-text)]">
                <Markdown>{message.content}</Markdown>
              </div>
            </div>
          ) : (
            <Markdown>{fullText ?? message.content}</Markdown>
          )}
        </div>
      </div>
    </div>
  );
}
