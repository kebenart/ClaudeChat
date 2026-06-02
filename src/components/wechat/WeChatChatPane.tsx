import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  ArrowDown,
  ArrowLeft,
  BellOff,
  Check,
  CheckCheck,
  FileClock,
  Loader2,
  MoreHorizontal,
  Pencil,
  Pin,
  PinOff,
  StopCircle,
} from 'lucide-react';

import { useWebSocket } from '../../contexts/WebSocketContext';
import { useIM } from '../../contexts/IMContext';
import { fetchMessages, fetchConversationContext, type ConversationContext } from '../../services/im/api';
import { clearDraft, loadDraft, saveDraft } from '../../services/im/drafts';
import { parseChoiceCard, parseImageCard, type WireMessage } from '../../services/im/protocol';
import { clampNickname } from '../../utils/nickname';

import { useSessionMeta } from './useSessionMeta';
import WeChatMessageList from './WeChatMessageList';
import WeChatTranscriptSheet from './WeChatTranscriptSheet';
import WeChatComposer, {
  type WeChatPendingImage,
  type WeChatSendPayload,
} from './WeChatComposer';
import {
  type WeChatMessage,
  type WeChatMessageRole,
  type WeChatSendStatus,
} from './WeChatMessageBubble';
import { canResend, resolveResendPayload, type ResendPayload } from './resend';

// MARK: - WeChatChatPane
//
// 1:1 port of the top-level macOS `ChatView` surface. Owns:
//   - The session header (pin icon + name + "正在输入中..." subtitle + 会话信息 ⋯).
//   - The scrollable messages area + the "N 条新消息" pill.
//   - The composer (writes back into the local draft for this session).
//
// Data wiring:
//   - On mount and when `session.id` changes, the pane loads history from the
//     IM hub's DISTILLED stream via `useIM().getMessages(sessionId)`
//     (user turns + assistant final results; tools/thinking removed).
//   - Subscribes to `useWebSocket().latestMessage` and folds live frames keyed
//     by `session.id` into the chat state for in-session streaming. Frame shapes
//     mirror `ServerEvent.decode` in `apple/Sources/ChatKit/Events.swift`.

export interface WeChatChatPaneSession {
  id: string;
  displayName: string;
  /** Project path used as `cwd` for new claude-command WS frames. */
  projectPath?: string | null;
  /** Whether the session row has the pin marker in the sidebar. */
  isPinned?: boolean;
  /** A not-yet-created session: the composer is shown immediately and the first
   *  send omits the sessionId so the server assigns one (session_created). */
  isNew?: boolean;
}

interface Props {
  session: WeChatChatPaneSession | null;
  onMenuClick?: () => void;
  onShowSessionInfo?: () => void;
  /** Whether the parent layout is in mobile (single-pane) mode. Affects the
   * composer style (WeChat-iOS row vs desktop toolbar). */
  isMobile?: boolean;
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers: JSONL → WeChatMessage
// ────────────────────────────────────────────────────────────────────────────

function asString(v: unknown): string {
  if (typeof v === 'string') return v;
  if (v === null || v === undefined) return '';
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

/**
 * Map one IM-hub wire message into a renderable WeChatMessage. Recognises the
 * interactive `kind:'choice'` rows (AskUserQuestion / ExitPlanMode): the JSON
 * `content` is parsed into `choice` so the bubble renders a 红包-style card
 * instead of dumping raw JSON as text. Everything else maps to a normal bubble.
 */
function decodeWireMessage(m: WireMessage): WeChatMessage {
  const base: WeChatMessage = {
    id: m.id,
    role: m.role === 'user' || m.role === 'system' ? m.role : 'assistant',
    content: m.content,
    createdAt: new Date(m.createdAt),
    seq: m.seq,
    conversationId: m.conversationId,
    truncated: m.truncated,
    fullLength: m.fullLength,
  };
  if (m.kind === 'choice') {
    const choice = parseChoiceCard(m.content);
    if (choice) return { ...base, choice };
  }
  if (m.kind === 'image') {
    const image = parseImageCard(m.content);
    if (image) return { ...base, image };
  }
  return base;
}

/** Compact a token count for the context line, e.g. 84321 → "84k", 1500000 → "1.5m". */
function compactTokens(n: number): string {
  if (n >= 1_000_000) {
    const m = n / 1_000_000;
    return `${m >= 10 ? Math.round(m) : m.toFixed(1).replace(/\.0$/, '')}m`;
  }
  if (n >= 1_000) return `${Math.round(n / 1_000)}k`;
  return String(n);
}

/**
 * Build the "正在输入中…" subtitle, enriched with the im:status progress when
 * available: "正在输入… · 执行了 N 个操作 · 正在运行 <tool>". The "执行了 N 个操作"
 * segment only appears when toolCount>0; the "· 正在运行 <tool>" segment only
 * when a currentTool is set. Falls back to the plain phrase otherwise.
 */
function buildTypingLabel(progress?: {
  toolCount: number;
  currentTool: string | null;
}): string {
  let label = '正在输入…';
  if (progress) {
    if (progress.toolCount > 0) label += ` · 执行了 ${progress.toolCount} 个操作`;
    if (progress.currentTool) label += ` · 正在运行 ${progress.currentTool}`;
  }
  return label;
}

// ────────────────────────────────────────────────────────────────────────────
// WS event handling
// ────────────────────────────────────────────────────────────────────────────

interface WsContext {
  /** Accumulated streaming text per assistant message id. */
  streamBuffersRef: React.MutableRefObject<Map<string, string>>;
  /** Pending permission requests we haven't displayed approve/reject for. */
  pendingApprovalsRef: React.MutableRefObject<Set<string>>;
}

function applyWsFrame(
  frame: Record<string, unknown>,
  sessionId: string,
  ctx: WsContext,
  setMessages: React.Dispatch<React.SetStateAction<WeChatMessage[]>>,
  setIsStreaming: React.Dispatch<React.SetStateAction<boolean>>,
  /**
   * When set, frames with no sessionId are still accepted (they're attributed
   * to the in-flight send started from this pane while the SDK was assigning
   * a real session id). See onSend.
   */
  hasInFlightSend: boolean,
): void {
  const kind = (frame.kind as string) || (frame.type as string) || '';
  const frameSid = (frame.sessionId as string) || '';
  // Terminal frames for an in-flight turn must always clear the typing state,
  // even if the SDK reported a different (forked) session id than the pane's —
  // otherwise "正在输入中" would linger after the reply finishes.
  const isTerminal = kind === 'complete' || kind === 'stream_end' || kind === 'error';
  // Terminal frames for an in-flight turn always fall through to the switch
  // (which clears streaming state), even if the SDK forked to a different
  // session id — otherwise "正在输入中" lingers after the reply finishes.
  if (!(isTerminal && hasInFlightSend)) {
    if (frameSid && frameSid !== sessionId) {
      return;
    }
    // No sid on the frame: only accept if we just sent something from this pane.
    // Otherwise it's a stale broadcast from a different (closed) conversation.
    if (!frameSid && !hasInFlightSend) {
      return;
    }
  }
  switch (kind) {
    case 'stream_delta': {
      const id = (frame.id as string) || 'live';
      const delta = asString(frame.content ?? frame.text ?? '');
      const buffers = ctx.streamBuffersRef.current;
      const next = (buffers.get(id) ?? '') + delta;
      buffers.set(id, next);
      setIsStreaming(true);
      setMessages((prev) => {
        const existing = prev.findIndex((m) => m.id === id && m.role === 'assistant');
        if (existing >= 0) {
          const copy = prev.slice();
          copy[existing] = { ...copy[existing], content: next, isStreaming: true };
          return copy;
        }
        return [
          ...prev,
          {
            id,
            role: 'assistant',
            createdAt: new Date(),
            content: next,
            isStreaming: true,
          },
        ];
      });
      return;
    }
    case 'stream_end': {
      const id = (frame.id as string) || 'live';
      ctx.streamBuffersRef.current.delete(id);
      setIsStreaming(false);
      setMessages((prev) =>
        prev.map((m) => (m.id === id ? { ...m, isStreaming: false } : m)),
      );
      return;
    }
    case 'assistant':
    case 'text': {
      const id = (frame.id as string) || `msg_${Date.now()}`;
      const content = asString(frame.content ?? frame.text ?? '');
      if (!content) return;
      setMessages((prev) => {
        if (prev.some((m) => m.id === id)) return prev;
        return [
          ...prev,
          {
            id,
            role: 'assistant',
            createdAt: new Date(),
            content,
          },
        ];
      });
      return;
    }
    case 'tool_use': {
      const id = (frame.id as string) || (frame.toolId as string) || `tu_${Date.now()}`;
      const name = (frame.toolName as string) || '';
      const input = frame.toolInput ?? frame.input;
      setMessages((prev) => {
        if (prev.some((m) => m.id === id)) return prev;
        return [
          ...prev,
          {
            id,
            role: 'tool',
            createdAt: new Date(),
            content: '',
            tool: { name, input, requestId: id },
          },
        ];
      });
      return;
    }
    case 'tool_result': {
      const toolId = (frame.toolId as string) || (frame.id as string) || '';
      const resultObj = frame.toolResult as { content?: string; isError?: boolean } | undefined;
      const output = asString(resultObj?.content ?? frame.content ?? '');
      const isError = Boolean(resultObj?.isError ?? frame.isError);
      setMessages((prev) =>
        prev.map((m) =>
          m.role === 'tool' && (m.tool?.requestId === toolId || m.id === toolId)
            ? {
                ...m,
                tool: {
                  ...(m.tool ?? { name: 'Result' }),
                  output,
                  isError,
                },
              }
            : m,
        ),
      );
      return;
    }
    case 'permission_request': {
      const requestId = (frame.requestId as string) || `pr_${Date.now()}`;
      const name = (frame.toolName as string) || '';
      const input = frame.input;
      ctx.pendingApprovalsRef.current.add(requestId);
      setMessages((prev) => {
        if (prev.some((m) => m.tool?.requestId === requestId)) return prev;
        return [
          ...prev,
          {
            id: `pa_${requestId}`,
            role: 'tool',
            createdAt: new Date(),
            content: '',
            tool: {
              name,
              input,
              requiresApproval: true,
              requestId,
            },
          },
        ];
      });
      return;
    }
    case 'permission_cancelled': {
      const requestId = (frame.requestId as string) || '';
      ctx.pendingApprovalsRef.current.delete(requestId);
      setMessages((prev) =>
        prev.map((m) =>
          m.tool?.requestId === requestId && m.tool.requiresApproval
            ? { ...m, tool: { ...m.tool, requiresApproval: false } }
            : m,
        ),
      );
      return;
    }
    case 'complete': {
      setIsStreaming(false);
      ctx.streamBuffersRef.current.clear();
      setMessages((prev) =>
        prev.map((m) => (m.isStreaming ? { ...m, isStreaming: false } : m)),
      );
      return;
    }
    case 'session_created': {
      // Surface as a no-op for the chat pane — the parent will swap the
      // session id when it sees this frame elsewhere.
      return;
    }
    case 'error': {
      const msg = asString(frame.error ?? frame.message ?? '未知错误');
      setMessages((prev) => [
        ...prev,
        {
          id: `err_${Date.now()}`,
          role: 'assistant',
          createdAt: new Date(),
          content: `⚠️ ${msg}`,
        },
      ]);
      setIsStreaming(false);
      return;
    }
    default:
      return;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Component
// ────────────────────────────────────────────────────────────────────────────

const SCROLL_THRESHOLD_PX = 80;
// History is rendered in pages from the tail; scrolling to the top reveals
// another page of older distilled messages (mirrors vue-chat's scroll-to-top
// load + "没有更多了" footer). Purely client-side over the already-synced
// local stream — no extra network round-trip.
const HISTORY_PAGE_SIZE = 30;
// How close to the top (px) before we auto-load the previous page.
const HISTORY_LOAD_THRESHOLD_PX = 48;

export default function WeChatChatPane({
  session,
  onMenuClick,
  // onShowSessionInfo: dead until a SessionInfoPanel ships. Accept it so the
  // type stays compatible but don't render the ⋯ button.
  onShowSessionInfo: _onShowSessionInfo,
  isMobile = false,
}: Props) {
  void _onShowSessionInfo;
  const { sendMessage, latestMessage, isConnected, connectionStatus } = useWebSocket();
  const { markRead, conversations: imConversations, progressByConversation } = useIM();
  // Distilled history loads straight from the server (always fresh) rather than
  // the local IndexedDB cache — the cache repeatedly went stale/empty across
  // dev iterations. 200 distilled turns is plenty and keeps the fetch cheap.
  const HISTORY_FETCH_LIMIT = 200;
  const meta = useSessionMeta(imConversations);
  const [headerMenuOpen, setHeaderMenuOpen] = useState(false);

  const [messages, setMessages] = useState<WeChatMessage[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  // Server-side older-history back-fill (distinct from the client-side
  // visibleCount windowing below). When the user scrolls to the top AND the
  // local window is fully revealed, fetch the previous page from the server.
  const [loadingOlder, setLoadingOlder] = useState(false);
  // Whether the server may still have older messages. Set false once the
  // initial fetch (or a back-fill) returns a short page.
  const [hasMoreOlder, setHasMoreOlder] = useState(false);
  const [isStreaming, setIsStreaming] = useState(false);
  // Read-only per-conversation context-window occupancy shown in the header.
  // Fetched when the conversation opens and refreshed after a reply completes
  // (when streaming flips off / new distilled messages land). null → render nothing.
  const [context, setContext] = useState<ConversationContext | null>(null);
  // Initialize from the per-conversation draft cache so a half-typed message
  // for the mounted session is restored immediately on first render.
  const [draft, setDraft] = useState<string>(() =>
    session?.id ? loadDraft(session.id) : '',
  );
  const [pendingQuote, setPendingQuote] = useState<string | null>(null);
  const [pendingImages, setPendingImages] = useState<WeChatPendingImage[]>([]);
  const [pendingFiles, setPendingFiles] = useState<string[]>([]);
  const [showTranscript, setShowTranscript] = useState(false);

  // Per-session derived state. Reset when the session changes.
  const sessionId = session?.id ?? null;
  // The IM hub's seq for this conversation — bumps every time a distilled
  // message lands (including replies driven elsewhere). Used to reconcile the
  // open pane when raw WS frames didn't reach it (e.g. just after a new session
  // was created, or a reply produced on another device).
  const convLastSeq = sessionId
    ? imConversations.find((c) => c.id === sessionId)?.lastSeq ?? 0
    : 0;
  // Richer im:status progress for the open conversation (undefined when not
  // processing). The typing row's VISIBILITY still follows the local
  // `isStreaming` (driven by WS stream frames + the optimistic send), but its
  // LABEL is enriched with tool progress when im:status has reported any.
  const convProgress = sessionId ? progressByConversation[sessionId] : undefined;
  // Show the typing row when either signal says we're mid-turn: the local WS
  // streaming state OR the server's im:status (which can light up before the
  // first stream_delta and stays accurate across devices).
  const showTyping = isStreaming || Boolean(convProgress?.isProcessing);
  const typingLabel = buildTypingLabel(convProgress);
  const streamBuffersRef = useRef<Map<string, string>>(new Map());
  const pendingApprovalsRef = useRef<Set<string>>(new Set());
  // Tracks a send for which the server hasn't returned `session_created`
  // yet. While set, no-sid frames are routed to this pane. Cleared on
  // `session_created` / `complete` / `stream_end`.
  const inFlightSendRef = useRef<string | null>(null);
  // Safety: if the server crashes mid-stream we'd otherwise spin the typing
  // indicator forever. Keep a 60s watchdog that resets `isStreaming`.
  const streamSafetyTimerRef = useRef<number | null>(null);

  // ── Per-conversation composer drafts ──────────────────────────────────
  // `draftRef` mirrors the latest draft each render so the save-on-switch
  // effect persists the current text rather than a stale closure value.
  const draftRef = useRef(draft);
  draftRef.current = draft;
  // Tracks the session whose draft is currently in the composer. Seeded with
  // the mount session so the first switch saves the right outgoing id.
  const prevSessionIdRef = useRef<string | null>(sessionId);
  // Set true while we swap drafts on a session change so the persist effect
  // below doesn't immediately write the just-loaded text back under the new
  // id (harmless, but avoids a redundant write).
  const loadingDraftRef = useRef(false);

  // Scroll handling
  const scrollerRef = useRef<HTMLDivElement | null>(null);
  const isScrolledAwayRef = useRef(false);
  const [newMessagePillCount, setNewMessagePillCount] = useState(0);

  // History windowing — render only the last `visibleCount` messages and grow
  // the window when the user scrolls to the top.
  const [visibleCount, setVisibleCount] = useState(HISTORY_PAGE_SIZE);
  // When a load-more grows the window, the list gets taller above the current
  // viewport. Stash the pre-grow scrollHeight so we can restore the anchor in
  // a layout effect and avoid a visible jump.
  const prependAnchorRef = useRef<number | null>(null);
  // Set true across a server-side older-history prepend so the messages.length
  // auto-scroll effect doesn't treat the new (older) messages as "new arrivals"
  // — they're back-fill above the viewport, not fresh tail messages, so they
  // must NOT bump the "N 条新消息" pill or scroll to the bottom.
  const serverPrependRef = useRef(false);
  // Memoized so the array identity is stable across composer keystrokes — a
  // fresh `.slice()` each render would defeat WeChatMessageList's React.memo.
  const visibleMessages = useMemo(
    () =>
      messages.length > visibleCount
        ? messages.slice(messages.length - visibleCount)
        : messages,
    [messages, visibleCount],
  );
  const hasMore = messages.length > visibleCount;

  // Fetch history when session changes.
  useEffect(() => {
    if (!sessionId) {
      setMessages([]);
      return;
    }
    // A brand-new session has no history to fetch — go straight to the composer.
    if (session?.isNew) {
      setMessages([]);
      setHistoryLoading(false);
      setHasMoreOlder(false);
      setVisibleCount(HISTORY_PAGE_SIZE);
      streamBuffersRef.current.clear();
      pendingApprovalsRef.current.clear();
      return;
    }
    let cancelled = false;
    setHistoryLoading(true);
    setMessages([]);
    setHasMoreOlder(false);
    setVisibleCount(HISTORY_PAGE_SIZE);
    prependAnchorRef.current = null;
    streamBuffersRef.current.clear();
    pendingApprovalsRef.current.clear();
    void (async () => {
      try {
        // History comes from the IM hub's DISTILLED stream (user turns +
        // assistant final results; tools/thinking removed), fetched live from
        // the server. Live streaming within the open session is still handled
        // by the WS folding below.
        const rows = await fetchMessages(sessionId, {
          numBefore: HISTORY_FETCH_LIMIT,
          numAfter: 0,
        });
        if (cancelled) return;
        const decoded: WeChatMessage[] = rows.map(decodeWireMessage);
        decoded.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
        setMessages(decoded);
        // A full page back from the tail means older history likely exists on
        // the server — enable the pull-down-to-load-older affordance.
        setHasMoreOlder(rows.length >= HISTORY_FETCH_LIMIT);
      } catch (err) {
        if (!cancelled) {
          console.error('[WeChatChatPane] IM history load failed', err);
        }
      } finally {
        if (!cancelled) setHistoryLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // Keyed only on sessionId — fetchMessages is a stable server call, and we
    // avoid re-running mid-turn so live-stream state isn't wiped.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  // Safety net only: if the dialog is EMPTY but the IM hub has messages for this
  // conversation (convLastSeq > 0), load them. This covers the raced/missed
  // cases (e.g. just after a new session was created) WITHOUT reloading on
  // every reply — normal replies already render live via the WS frames below,
  // so we must not re-fetch + replace the whole list each turn (that read as a
  // laggy "reload" after every answer).
  useEffect(() => {
    if (!sessionId || session?.isNew || isStreaming || convLastSeq === 0) return;
    if (messages.length > 0) return; // already populated — don't churn
    let cancelled = false;
    void (async () => {
      try {
        const rows = await fetchMessages(sessionId, {
          numBefore: HISTORY_FETCH_LIMIT,
          numAfter: 0,
        });
        if (cancelled) return;
        // Never wipe a loaded dialog: if the server returns nothing for this
        // conversation, leave the existing messages untouched. Only reconcile
        // when we actually have authoritative data.
        if (rows.length === 0) return;
        const decoded: WeChatMessage[] = rows.map(decodeWireMessage);
        decoded.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
        setMessages((prev) => {
          // Keep any not-yet-distilled optimistic/streaming messages (ids the
          // IM stream doesn't know about) appended after the authoritative set.
          const imIds = new Set(decoded.map((m) => m.id));
          const extras = prev.filter(
            (m) => !imIds.has(m.id) && (m.isStreaming || m.sendStatus === 'sending' || m.sendStatus === 'failed'),
          );
          return [...decoded, ...extras];
        });
      } catch {
        // best-effort reconcile
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, convLastSeq, isStreaming, messages.length]);

  // WS frame folding
  useEffect(() => {
    if (!latestMessage || !sessionId) return;
    if (typeof latestMessage !== 'object') return;
    const frame = latestMessage as Record<string, unknown>;
    // Interactive choice cards arrive live as an im:message (NOT a claude
    // stream frame), so they don't flow through applyWsFrame. Fold them in
    // directly: insert a new card or UPSERT an existing one (the same message
    // id is re-broadcast when it flips to answered) into this pane's stream.
    if (frame.type === 'im:message') {
      const wire = frame.message as WireMessage | undefined;
      if (wire && wire.kind === 'choice' && wire.conversationId === sessionId) {
        const decoded = decodeWireMessage(wire);
        setMessages((prev) => {
          const idx = prev.findIndex((m) => m.id === decoded.id);
          if (idx >= 0) {
            const copy = prev.slice();
            copy[idx] = { ...copy[idx], ...decoded };
            return copy;
          }
          return [...prev, decoded];
        });
      }
      return;
    }
    applyWsFrame(
      frame,
      sessionId,
      { streamBuffersRef, pendingApprovalsRef },
      setMessages,
      setIsStreaming,
      inFlightSendRef.current !== null,
    );
    // Terminal frames clear the in-flight marker.
    const kind = (frame.kind as string) || (frame.type as string) || '';
    if (
      kind === 'session_created' ||
      kind === 'complete' ||
      kind === 'stream_end' ||
      kind === 'error'
    ) {
      inFlightSendRef.current = null;
      if (streamSafetyTimerRef.current !== null) {
        window.clearTimeout(streamSafetyTimerRef.current);
        streamSafetyTimerRef.current = null;
      }
    }
    // Any incoming frame postpones the safety timeout.
    if (streamSafetyTimerRef.current !== null) {
      window.clearTimeout(streamSafetyTimerRef.current);
      streamSafetyTimerRef.current = window.setTimeout(() => {
        setIsStreaming(false);
        streamSafetyTimerRef.current = null;
      }, 60_000);
    }
  }, [latestMessage, sessionId]);

  // Cleanup safety timer on unmount / session change.
  useEffect(() => {
    return () => {
      if (streamSafetyTimerRef.current !== null) {
        window.clearTimeout(streamSafetyTimerRef.current);
        streamSafetyTimerRef.current = null;
      }
    };
  }, [sessionId]);

  // ── Per-conversation context occupancy ────────────────────────────────
  // Fetch when the conversation opens, and refresh once a reply completes.
  // Re-runs on: session change (open), isStreaming → false (reply done), and
  // convLastSeq bump (a new distilled message landed). Skipped while streaming
  // so we don't hammer the endpoint mid-turn. Clears on session change.
  useEffect(() => {
    if (!sessionId || session?.isNew) {
      setContext(null);
      return;
    }
    if (isStreaming) return;
    let cancelled = false;
    void (async () => {
      const ctx = await fetchConversationContext(sessionId);
      if (!cancelled) setContext(ctx);
    })();
    return () => {
      cancelled = true;
    };
  }, [sessionId, isStreaming, convLastSeq, session?.isNew]);

  // Listen for cross-tab "insert into composer" requests dispatched by the
  // Discover tab. The Discover tab can't reach our draft state directly, so
  // we route via a window CustomEvent. Only consume it when we have an
  // active session — otherwise Discover already alerts the user.
  useEffect(() => {
    const handler = (e: Event) => {
      const detail = (e as CustomEvent<{ text?: string }>).detail;
      if (!detail?.text) return;
      setDraft((cur) => (cur ? cur + ' ' + detail.text : detail.text!));
    };
    window.addEventListener('wechat:insert-into-composer', handler as EventListener);
    return () => window.removeEventListener('wechat:insert-into-composer', handler as EventListener);
  }, []);

  // On session change: persist the OUTGOING session's draft (read the latest
  // text via draftRef to avoid a stale-closure save), then load the INCOMING
  // session's draft into the composer. prevSessionIdRef tracks which id the
  // current composer text belongs to.
  useEffect(() => {
    const prevId = prevSessionIdRef.current;
    if (prevId === sessionId) return;
    if (prevId) saveDraft(prevId, draftRef.current);
    loadingDraftRef.current = true;
    const next = sessionId ? loadDraft(sessionId) : '';
    setDraft(next);
    draftRef.current = next;
    prevSessionIdRef.current = sessionId;
  }, [sessionId]);

  // Persist the current session's draft on every change. Skip the write that
  // immediately follows a load-on-switch (the just-loaded value).
  useEffect(() => {
    if (loadingDraftRef.current) {
      loadingDraftRef.current = false;
      return;
    }
    if (!sessionId) return;
    saveDraft(sessionId, draft);
  }, [draft, sessionId]);

  // Auto-scroll to bottom unless the user is scrolled away.
  useLayoutEffect(() => {
    const el = scrollerRef.current;
    if (!el) return;
    // A server-side older-history prepend grows messages.length from the TOP.
    // Skip the bottom-scroll / pill bump entirely — the dedicated prepend
    // layout effect below restores the viewport to the same message.
    if (serverPrependRef.current) return;
    if (!isScrolledAwayRef.current) {
      el.scrollTop = el.scrollHeight;
      setNewMessagePillCount(0);
    } else {
      setNewMessagePillCount((c) => c + 1);
    }
  }, [messages.length]);

  // After a history page is prepended (client window grow OR a server back-fill),
  // restore the scroll anchor so the viewport stays on the same message instead
  // of jumping to the new top.
  useLayoutEffect(() => {
    const el = scrollerRef.current;
    if (!el || prependAnchorRef.current === null) return;
    el.scrollTop += el.scrollHeight - prependAnchorRef.current;
    prependAnchorRef.current = null;
    serverPrependRef.current = false;
  }, [visibleCount, messages.length]);

  // Latest loadOlderFromServer, referenced from onScroll (which is defined
  // earlier). Lets onScroll trigger a server back-fill without a declaration
  // cycle between the two useCallbacks.
  const loadOlderRef = useRef<() => void>(() => {});
  // Mirror of visibleCount so onScroll can decide synchronously whether the
  // local window is fully revealed (without taking visibleCount as a dep, which
  // would re-create the scroll handler on every page reveal).
  const visibleCountRef = useRef(visibleCount);
  visibleCountRef.current = visibleCount;

  const onScroll = useCallback(() => {
    const el = scrollerRef.current;
    if (!el) return;
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const away = distanceFromBottom > SCROLL_THRESHOLD_PX;
    isScrolledAwayRef.current = away;
    if (!away) setNewMessagePillCount(0);
    // Near the top → reveal the previous page (anchor preserved in the layout
    // effect above). Guard with the anchor ref so one scroll loads one page.
    if (el.scrollTop <= HISTORY_LOAD_THRESHOLD_PX && prependAnchorRef.current === null) {
      if (visibleCountRef.current < messages.length) {
        // Still have locally-loaded messages to reveal — grow the client window.
        prependAnchorRef.current = el.scrollHeight;
        setVisibleCount((c) => c + HISTORY_PAGE_SIZE);
      } else if (messages.length > 0) {
        // Local window fully revealed — reach the server for older history.
        loadOlderRef.current();
      }
    }
  }, [messages.length]);

  // Memoized so WeChatMessageList (React.memo) isn't re-rendered on every
  // composer keystroke — an inline arrow here would change identity each render
  // and defeat the memo.
  const onQuote = useCallback((content: string) => {
    setPendingQuote(content);
  }, []);

  const jumpToBottom = useCallback(() => {
    const el = scrollerRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
    isScrolledAwayRef.current = false;
    setNewMessagePillCount(0);
  }, []);

  // ── Load older history from the server (pull-down-at-top) ──────────────
  // The cold-start /sync only caps to recent-N per conversation, so older
  // messages exist server-side but aren't in `messages`. When the user reaches
  // the top, fetch the page just BEFORE the oldest loaded seq and PREPEND it
  // (deduped by id), preserving the scroll position. `hasMoreOlder` goes false
  // once the server returns a short page.
  const loadOlderFromServer = useCallback(async () => {
    if (!sessionId || loadingOlder || !hasMoreOlder) return;
    // Anchor at the oldest loaded distilled message that carries a wire seq.
    let oldestSeq: number | undefined;
    for (const m of messages) {
      if (typeof m.seq === 'number' && (oldestSeq === undefined || m.seq < oldestSeq)) {
        oldestSeq = m.seq;
      }
    }
    if (oldestSeq === undefined) return;
    const el = scrollerRef.current;
    // Measure scrollHeight BEFORE the prepend so the layout effect can restore
    // scrollTop after the older messages grow the list upward.
    if (el) prependAnchorRef.current = el.scrollHeight;
    serverPrependRef.current = true;
    setLoadingOlder(true);
    try {
      const rows = await fetchMessages(sessionId, {
        anchorSeq: oldestSeq,
        numBefore: 30,
        numAfter: 0,
      });
      // A short page means the server has nothing older left.
      setHasMoreOlder(rows.length >= 30);
      if (rows.length === 0) {
        prependAnchorRef.current = null;
        serverPrependRef.current = false;
        return;
      }
      const older: WeChatMessage[] = rows.map(decodeWireMessage);
      setMessages((prev) => {
        const known = new Set(prev.map((m) => m.id));
        const merged = [...older.filter((m) => !known.has(m.id)), ...prev];
        merged.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
        return merged;
      });
      // Grow the client-side render window so the prepended page is actually
      // rendered (otherwise visibleMessages would still clip it off the top).
      setVisibleCount((c) => c + older.length);
    } catch (err) {
      console.error('[WeChatChatPane] load older failed', err);
      prependAnchorRef.current = null;
      serverPrependRef.current = false;
    } finally {
      setLoadingOlder(false);
    }
  }, [sessionId, loadingOlder, hasMoreOlder, messages]);

  // Keep the scroll-handler's ref pointing at the latest loader closure.
  useEffect(() => {
    loadOlderRef.current = () => {
      void loadOlderFromServer();
    };
  }, [loadOlderFromServer]);

  // ── Send ──────────────────────────────────────────────────────────────
  // Core wire-send: pushes one already-composed user turn over the WS chat
  // path and drives the optimistic bubble's status (sending → sent / failed).
  // Shared by the first send AND the failed-bubble resend so both go through
  // the exact same socket frame and status transitions.
  const wireSend = useCallback(
    (msgId: string, text: string, images?: { data: string; name: string }[]) => {
      if (!sessionId) return;
      // Resume only when the session is known to be persisted. New sessions
      // (zero history loaded) start fresh — the SDK rejects resume on an
      // unknown JSONL file otherwise. Mirrors macOS AppViewModel logic.
      const hasHistory = messages.some(
        (m) => m.role !== 'system' && m.id !== msgId && !m.id.startsWith('opt_'),
      );
      // A brand-new session must NOT send a sessionId (the server treats any
      // provided id as a resume target). Omit it so the SDK creates a session
      // and emits `session_created` with the real id, which the parent adopts.
      const isNew = Boolean(session?.isNew);
      const wirePayload: Record<string, unknown> = {
        type: 'claude-command',
        command: text,
        options: {
          ...(isNew ? {} : { sessionId }),
          projectPath: session?.projectPath ?? undefined,
          cwd: session?.projectPath ?? undefined,
          resume: isNew ? false : hasHistory,
          // IM sessions auto-approve everything — no tool-approval prompts. The
          // server maps this to the SDK's bypassPermissions canUseTool path.
          permissionMode: 'bypassPermissions',
          // Idempotency key for "reliable send": reuse the optimistic message id
          // so a resend (manual red-! tap OR auto-flush on reconnect) is a
          // server-side no-op instead of a second Claude invocation.
          clientMsgId: msgId,
        },
      };
      if (images && images.length > 0) {
        (wirePayload.options as Record<string, unknown>).images = images;
      }
      try {
        console.debug('[ChatPane] sending', wirePayload);
        sendMessage(wirePayload);
        // Show "正在输入中..." immediately on send — we won't wait for the
        // first stream_delta frame to flip it on. The complete / error / abort
        // paths in applyWsFrame turn it off.
        setIsStreaming(true);
        // Mark this send as in-flight so no-sid WS frames are attributed here
        // until session_created / complete / stream_end clears it.
        inFlightSendRef.current = msgId;
        // Kick the safety watchdog — if no frames arrive within 60s, clear
        // the typing indicator so the UI doesn't spin forever on a crash.
        if (streamSafetyTimerRef.current !== null) {
          window.clearTimeout(streamSafetyTimerRef.current);
        }
        streamSafetyTimerRef.current = window.setTimeout(() => {
          setIsStreaming(false);
          streamSafetyTimerRef.current = null;
        }, 60_000);
        // Mark as sent shortly after — server-side will eventually upgrade us
        // to delivered via the next assistant frame.
        window.setTimeout(() => {
          setMessages((prev) =>
            prev.map<WeChatMessage>((m) =>
              m.id === msgId
                ? { ...m, sendStatus: 'sent' satisfies WeChatSendStatus, sendError: undefined }
                : m,
            ),
          );
        }, 150);
      } catch (err) {
        setMessages((prev) =>
          prev.map<WeChatMessage>((m) =>
            m.id === msgId
              ? {
                  ...m,
                  sendStatus: 'failed' satisfies WeChatSendStatus,
                  sendError: err instanceof Error ? err.message : '发送失败',
                }
              : m,
          ),
        );
      }
    },
    [sessionId, session?.projectPath, session?.isNew, sendMessage, messages],
  );

  const onSend = useCallback(
    (payload: WeChatSendPayload) => {
      if (!sessionId) return;
      const optimisticId = `opt_${Date.now()}`;
      let text = payload.text;
      if (payload.quote) {
        text = `> ${payload.quote.split('\n').slice(0, 3).join('\n> ')}\n\n${text}`;
      }
      if (payload.files && payload.files.length > 0) {
        const refs = payload.files.map((p) => `@${p}`).join(' ');
        text = `${refs}\n${text}`;
      }
      const images =
        payload.images && payload.images.length > 0
          ? payload.images.map((img) => ({ data: img.dataURI, name: img.filename }))
          : undefined;
      // Don't drop the user's draft on disconnect — show a failed bubble with
      // a clear reason instead of silently dropping. The captured `resend`
      // payload lets the user tap the red ❗ to retry verbatim once reconnected.
      if (!isConnected) {
        setMessages((prev) => [
          ...prev,
          {
            id: optimisticId,
            role: 'user',
            createdAt: new Date(),
            content: text,
            sendStatus: 'failed',
            sendError: 'WebSocket 未连接。请检查服务器或网络后重试。',
            resend: { text, images },
          },
        ]);
        return;
      }
      const optimistic: WeChatMessage = {
        id: optimisticId,
        role: 'user',
        createdAt: new Date(),
        content: text,
        sendStatus: 'sending',
        resend: { text, images },
      };
      setMessages((prev) => [...prev, optimistic]);
      wireSend(optimisticId, text, images);
      // Clear composer state ONLY after the optimistic bubble + enqueue. The
      // composer also clears its own value (→ setDraft('')), but drop the
      // cached draft explicitly so a reload doesn't restore a sent message.
      clearDraft(sessionId);
      setDraft('');
      setPendingQuote(null);
      setPendingImages([]);
      setPendingFiles([]);
    },
    [sessionId, isConnected, wireSend],
  );

  // ── Resend a failed outgoing bubble ───────────────────────────────────
  // Reuses the SAME message id (no duplicate bubble) — flip its status back to
  // 'sending' and re-run the identical wire-send path. Re-checks connectivity
  // so a still-offline retry returns to 'failed' with a clear reason.
  const onResend = useCallback(
    (msgId: string) => {
      let payload: ResendPayload | null = null;
      setMessages((prev) =>
        prev.map<WeChatMessage>((m) => {
          if (m.id !== msgId || !canResend(m)) return m;
          payload = resolveResendPayload(m);
          return { ...m, sendStatus: 'sending', sendError: undefined };
        }),
      );
      const resendPayload = payload as ResendPayload | null;
      if (!resendPayload) return;
      if (!isConnected) {
        setMessages((prev) =>
          prev.map<WeChatMessage>((m) =>
            m.id === msgId
              ? {
                  ...m,
                  sendStatus: 'failed' satisfies WeChatSendStatus,
                  sendError: 'WebSocket 未连接。请检查服务器或网络后重试。',
                }
              : m,
          ),
        );
        return;
      }
      wireSend(msgId, resendPayload.text, resendPayload.images);
    },
    [isConnected, wireSend],
  );

  // ── Auto-resend on reconnect (outbox flush) ───────────────────────────
  // When the WS transitions INTO 'online' (edge, not every status change),
  // auto-resend every failed outgoing bubble. Each resend reuses its message
  // id as the clientMsgId, so the server dedups any that actually landed — no
  // double Claude invocation. The manual red-! tap still works independently.
  const prevConnStatusRef = useRef(connectionStatus);
  useEffect(() => {
    const prev = prevConnStatusRef.current;
    prevConnStatusRef.current = connectionStatus;
    if (connectionStatus !== 'online' || prev === 'online') return;
    const failedIds = messages
      .filter((m) => m.role === 'user' && m.sendStatus === 'failed' && canResend(m))
      .map((m) => m.id);
    for (const id of failedIds) onResend(id);
  }, [connectionStatus, messages, onResend]);

  // ── Approve / reject tool calls ───────────────────────────────────────
  const onApprove = useCallback(
    (requestId: string) => {
      sendMessage({
        type: 'claude-permission-response',
        requestId,
        allow: true,
      });
    },
    [sendMessage],
  );
  const onReject = useCallback(
    (requestId: string) => {
      sendMessage({
        type: 'claude-permission-response',
        requestId,
        allow: false,
      });
    },
    [sendMessage],
  );

  // ── Interactive choice cards (AskUserQuestion / ExitPlanMode) ──────────
  // Send the answer over the SAME chat WS used for messages. AskUserQuestion
  // folds the per-question selections into `answers`; ExitPlanMode sends a
  // boolean `approve`. Optimistic dismissal lives in WeChatChoiceCard; the
  // server flips the same message id to answered and it re-syncs into the card.
  const onChoiceAnswer = useCallback(
    (requestId: string, answers: Record<string, string[]>) => {
      sendMessage({
        type: 'claude-permission-response',
        requestId,
        answers,
      });
    },
    [sendMessage],
  );
  const onChoicePlan = useCallback(
    (requestId: string, approve: boolean) => {
      sendMessage({
        type: 'claude-permission-response',
        requestId,
        approve,
      });
    },
    [sendMessage],
  );

  // Once delivered to assistant, upgrade the most recent user message to
  // `delivered` so the double-check appears.
  useEffect(() => {
    const last = messages[messages.length - 1];
    if (!last || last.role !== 'assistant') return;
    setMessages((prev) => {
      let changed = false;
      const next = prev.map((m) => {
        if (m.role === 'user' && m.sendStatus === 'sent') {
          changed = true;
          return { ...m, sendStatus: 'delivered' as WeChatSendStatus };
        }
        return m;
      });
      return changed ? next : prev;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [messages[messages.length - 1]?.id]);

  // Empty state
  const isEmpty = !session;
  const hasMessages = messages.length > 0;

  // ── UI ────────────────────────────────────────────────────────────────
  if (isEmpty) {
    return (
      <div className="flex h-full w-full flex-col items-center justify-center bg-[var(--wc-bg-chat)]">
        <p className="text-[14px] text-[var(--wc-text-secondary)]">选择一个会话开始聊天</p>
      </div>
    );
  }

  // Header display: a user note (备注名) overrides the derived session name, and
  // pin/mute state come from the shared meta store (same source as the sidebar).
  const noteName = sessionId ? meta.noteOf(sessionId) : '';
  const headerName = noteName || session.displayName;
  const pinnedNow = sessionId ? meta.isPinned(sessionId) : false;
  const mutedNow = sessionId ? meta.isMuted(sessionId) : false;

  const renameViaPrompt = () => {
    if (!sessionId) return;
    const next = window.prompt('设置备注名', headerName);
    if (next === null) return;
    meta.setNote(sessionId, next.trim());
  };

  return (
    <div className="flex h-full w-full min-w-0 flex-col overflow-x-hidden bg-[var(--wc-bg-chat)]">
      {/* Header */}
      <div className="flex h-[56px] shrink-0 items-center gap-2 border-b border-[var(--wc-border)] bg-[var(--wc-bg-header)] px-4">
        {/* Back button — only shown when the parent gives us an onMenuClick
            (i.e. mobile single-pane mode). Matches WeChat-iOS chat detail. */}
        {onMenuClick && (
          <button
            type="button"
            onClick={onMenuClick}
            className="-ml-1 rounded p-1 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            title="返回"
            aria-label="返回会话列表"
          >
            <ArrowLeft className="h-5 w-5" />
          </button>
        )}
        <div className="flex min-w-0 flex-col">
          <div className="flex items-center gap-1.5">
            {pinnedNow && <Pin className="h-2.5 w-2.5 fill-[var(--wc-accent)] text-[var(--wc-accent)]" />}
            <span className="truncate text-[14px] font-medium text-[var(--wc-text-primary)]">
              {clampNickname(headerName)}
            </span>
            {mutedNow && <BellOff className="h-2.5 w-2.5 shrink-0 text-[var(--wc-text-secondary)]" />}
          </div>
          {!showTyping && context && (
            <span className="truncate text-[11px] text-[var(--wc-text-secondary)]">
              上下文 {Math.max(0, Math.min(100, Math.round(context.pct)))}% ·{' '}
              {compactTokens(context.contextTokens)}/{compactTokens(context.windowTokens)}
            </span>
          )}
          {showTyping && (
            <div className="flex items-center gap-1.5">
              <span className="truncate text-[11px] text-[var(--wc-accent)]">{typingLabel}</span>
              <button
                type="button"
                onClick={() => {
                  sendMessage({ type: 'abort-session', sessionId });
                  // Clear local streaming state immediately so the UI doesn't
                  // lag the user's intent — the server will emit `complete`
                  // with aborted:true shortly after.
                  setIsStreaming(false);
                  setMessages((prev) =>
                    prev.map((m) => (m.isStreaming ? { ...m, isStreaming: false } : m)),
                  );
                  inFlightSendRef.current = null;
                }}
                className="inline-flex items-center gap-0.5 rounded-full bg-red-50 px-1.5 py-0.5 text-[10px] text-red-600 hover:bg-red-100 dark:bg-red-950/40 dark:text-red-400 dark:hover:bg-red-950/70"
                title="中断当前回复"
              >
                <StopCircle className="h-3 w-3" />
                中断
              </button>
            </div>
          )}
        </div>
        <div className="flex-1" />
        {/* 查看完整记录 — raw transcript (tools/thinking) hidden from the IM stream. */}
        <button
          type="button"
          onClick={() => setShowTranscript(true)}
          className="rounded p-1.5 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
          title="查看完整记录"
          aria-label="查看完整记录"
        >
          <FileClock className="h-[18px] w-[18px]" />
        </button>
        {/* ⋯ menu — conversation actions (pin / mute / rename / mark read). */}
        <div className="relative">
          <button
            type="button"
            onClick={() => setHeaderMenuOpen((v) => !v)}
            className="rounded p-1.5 text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]"
            title="更多"
            aria-label="更多操作"
            aria-haspopup="menu"
            aria-expanded={headerMenuOpen}
          >
            <MoreHorizontal className="h-[18px] w-[18px]" />
          </button>
          {headerMenuOpen && (
            <>
              {/* Click-away backdrop */}
              <div
                className="fixed inset-0 z-40"
                onClick={() => setHeaderMenuOpen(false)}
                aria-hidden
              />
              <div
                role="menu"
                className="absolute right-0 top-full z-50 mt-1 min-w-[160px] overflow-hidden rounded-md border border-[var(--wc-border)] bg-[var(--wc-bg-app)] py-1 text-[13px] text-[var(--wc-text-primary)] shadow-lg"
              >
                <HeaderMenuItem
                  icon={pinnedNow ? <PinOff className="h-3.5 w-3.5" /> : <Pin className="h-3.5 w-3.5" />}
                  label={pinnedNow ? '取消置顶' : '置顶聊天'}
                  onClick={() => {
                    if (sessionId) meta.togglePin(sessionId);
                    setHeaderMenuOpen(false);
                  }}
                />
                <HeaderMenuItem
                  icon={<BellOff className="h-3.5 w-3.5" />}
                  label={mutedNow ? '取消免打扰' : '消息免打扰'}
                  onClick={() => {
                    if (sessionId) meta.toggleMute(sessionId);
                    setHeaderMenuOpen(false);
                  }}
                />
                <HeaderMenuItem
                  icon={<Pencil className="h-3.5 w-3.5" />}
                  label="设置备注名"
                  onClick={() => {
                    setHeaderMenuOpen(false);
                    renameViaPrompt();
                  }}
                />
                <HeaderMenuItem
                  icon={
                    newMessagePillCount > 0 ? (
                      <CheckCheck className="h-3.5 w-3.5" />
                    ) : (
                      <Check className="h-3.5 w-3.5" />
                    )
                  }
                  label="标为已读"
                  onClick={() => {
                    if (sessionId) void markRead(sessionId);
                    setHeaderMenuOpen(false);
                  }}
                />
                <div className="my-1 h-px bg-[var(--wc-border)]" />
                <HeaderMenuItem
                  icon={<FileClock className="h-3.5 w-3.5" />}
                  label="查看完整记录"
                  onClick={() => {
                    setShowTranscript(true);
                    setHeaderMenuOpen(false);
                  }}
                />
              </div>
            </>
          )}
        </div>
      </div>

      {showTranscript && sessionId && (
        <WeChatTranscriptSheet
          conversationId={sessionId}
          title={session.displayName}
          onClose={() => setShowTranscript(false)}
        />
      )}

      {/* Messages */}
      <div
        className="relative flex-1 overflow-hidden"
        onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; }}
        onDrop={(e) => {
          e.preventDefault();
          const files = Array.from(e.dataTransfer.files ?? []);
          if (files.length === 0) return;
          const newImages: WeChatPendingImage[] = [];
          const newPaths: string[] = [];
          Promise.all(files.map(async (file) => {
            const isImg = file.type.startsWith('image/');
            if (isImg) {
              const buf = await file.arrayBuffer();
              const b64 = btoa(String.fromCharCode(...new Uint8Array(buf)));
              newImages.push({
                id: `pi_${Date.now()}_${file.name}`,
                filename: file.name,
                mimeType: file.type,
                dataURI: `data:${file.type};base64,${b64}`,
              });
            } else {
              // Web can't get a real disk path from drag-drop (sandbox), so
              // fall back to the filename — the user can edit before send.
              newPaths.push(file.name);
            }
          })).then(() => {
            if (newImages.length > 0) {
              setPendingImages((prev) => [...prev, ...newImages]);
            }
            if (newPaths.length > 0) {
              setPendingFiles((prev) => [...prev, ...newPaths]);
            }
          });
        }}
      >
        <div
          ref={scrollerRef}
          onScroll={onScroll}
          className="h-full overflow-y-auto overflow-x-hidden overscroll-contain"
        >
          {historyLoading && !hasMessages ? (
            <div className="flex h-full flex-col items-center justify-center gap-2 text-[12px] text-[var(--wc-text-secondary)]">
              <Loader2 className="h-4 w-4 animate-spin" />
              加载历史消息...
            </div>
          ) : !hasMessages ? (
            <div className="flex h-full flex-col items-center justify-center gap-2">
              <span className="text-[14px] font-medium text-[var(--wc-text-secondary)]">
                这是一个新会话
              </span>
              <span className="text-[11px] text-[var(--wc-text-time)]">
                发一句问候开始吧
              </span>
            </div>
          ) : (
            <>
              {/* Top-of-list history sentinel. Older messages load in two
                  layers: (1) the locally-synced tail is revealed incrementally
                  as the client window grows; (2) once that's exhausted, scrolling
                  to the top fetches the previous page from the server (cold-start
                  /sync only kept recent-N). "加载更早的消息…" shows while a server
                  fetch is in flight; "没有更多了" once fully back-filled. */}
              {loadingOlder ? (
                <div className="flex items-center justify-center gap-1.5 py-2 text-[11px] text-[var(--wc-text-secondary)]">
                  <Loader2 className="h-3 w-3 animate-spin" />
                  加载更早的消息…
                </div>
              ) : hasMore || hasMoreOlder ? (
                <div className="py-2 text-center text-[11px] text-[var(--wc-text-secondary)]">
                  下拉加载更早的消息…
                </div>
              ) : messages.length > HISTORY_PAGE_SIZE ? (
                <div className="py-2 text-center text-[11px] text-[var(--wc-text-time)]">
                  没有更多了
                </div>
              ) : null}
              <WeChatMessageList
                messages={visibleMessages}
                isStreaming={isStreaming}
                onApprove={onApprove}
                onReject={onReject}
                onQuote={onQuote}
                onResend={onResend}
                onChoiceAnswer={onChoiceAnswer}
                onChoicePlan={onChoicePlan}
                contactSeed={sessionId ?? undefined}
                contactTitle={headerName}
              />
            </>
          )}
        </div>

        {/* "N 条新消息" pill */}
        {newMessagePillCount > 0 && (
          <button
            type="button"
            onClick={jumpToBottom}
            className="absolute bottom-3 left-1/2 inline-flex -translate-x-1/2 items-center gap-1 rounded-full bg-[var(--wc-accent)] px-3 py-1.5 text-[12px] text-white shadow-lg"
          >
            <ArrowDown className="h-3 w-3" />
            {newMessagePillCount} 条新消息
          </button>
        )}
      </div>

      {/* Composer */}
      <WeChatComposer
        value={draft}
        onChange={setDraft}
        projectPath={session.projectPath ?? null}
        pendingQuote={pendingQuote}
        onClearQuote={() => setPendingQuote(null)}
        pendingImages={pendingImages}
        onRemoveImage={(id) => setPendingImages((prev) => prev.filter((i) => i.id !== id))}
        pendingFiles={pendingFiles}
        onRemoveFile={(p) => setPendingFiles((prev) => prev.filter((x) => x !== p))}
        onSendMessage={onSend}
        disabled={!isConnected}
        autoFocus={!isMobile}
        isMobile={isMobile}
      />
    </div>
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Header ⋯ menu item
// ────────────────────────────────────────────────────────────────────────────

function HeaderMenuItem({
  icon,
  label,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className="flex w-full items-center gap-2 px-3 py-1.5 text-left transition-colors hover:bg-[var(--wc-item-hover)]"
    >
      <span className="text-[var(--wc-text-secondary)]">{icon}</span>
      {label}
    </button>
  );
}

// Re-export the message type so parents can build messages externally if needed.
export type { WeChatMessage, WeChatMessageRole, WeChatSendStatus };
