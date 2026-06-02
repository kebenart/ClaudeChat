import { authenticatedFetch } from '@/utils/api.js';
import {
  buildSyncUrl,
  buildMessagesUrl,
  buildMessageContentUrl,
  buildTranscriptUrl,
} from '@/services/im/urls.js';
import type { SyncResponse, WireMessage } from '@/services/im/protocol.js';

export {
  buildSyncUrl,
  buildMessagesUrl,
  buildMessageContentUrl,
  buildTranscriptUrl,
} from '@/services/im/urls.js';

export type TranscriptEntryKind = 'text' | 'tool_use' | 'tool_result' | 'thinking' | 'meta';

export interface TranscriptEntry {
  id: string;
  type: string;
  /** jsonl role ('user' | 'assistant' | …) — drives bubble side. */
  role?: string;
  /** Coarse classification; non-'text' kinds are folded in the viewer. */
  kind?: TranscriptEntryKind;
  summary: string;
  hasBlob: boolean;
}

export interface TranscriptPage {
  entries: TranscriptEntry[];
  hasMoreBefore: boolean;
  hasMoreAfter: boolean;
}

export async function fetchSync(since: number, recent?: number): Promise<SyncResponse> {
  const res = await authenticatedFetch(buildSyncUrl(since, recent));
  if (!res.ok) throw new Error(`im sync failed: ${res.status}`);
  return (await res.json()) as SyncResponse;
}

export async function fetchMessages(
  conversationId: string,
  opts: { anchorSeq?: number; numBefore: number; numAfter: number }
): Promise<WireMessage[]> {
  const res = await authenticatedFetch(buildMessagesUrl(conversationId, opts));
  if (!res.ok) throw new Error(`im messages failed: ${res.status}`);
  const body = (await res.json()) as { messages: WireMessage[] };
  return body.messages ?? [];
}

/**
 * Lazy full-text for a truncated message (Server P2). GET
 * /api/im/conversations/<id>/messages/<messageId>/content → { content }.
 * `messageId` is the same id carried on the /sync + im:message WireMessage.
 */
export async function fetchMessageContent(
  conversationId: string,
  messageId: string
): Promise<string> {
  const res = await authenticatedFetch(buildMessageContentUrl(conversationId, messageId));
  if (!res.ok) throw new Error(`im message content failed: ${res.status}`);
  const body = (await res.json()) as { content?: string };
  return body.content ?? '';
}

export async function fetchTranscript(
  conversationId: string,
  opts: { anchor?: string; numBefore: number; numAfter: number }
): Promise<TranscriptPage> {
  const res = await authenticatedFetch(buildTranscriptUrl(conversationId, opts));
  if (!res.ok) throw new Error(`im transcript failed: ${res.status}`);
  return (await res.json()) as TranscriptPage;
}

export async function postRead(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void> {
  const res = await authenticatedFetch(`/api/im/conversations/${encodeURIComponent(conversationId)}/read`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ deviceId, lastReadSeq }),
  });
  if (!res.ok) throw new Error(`im read failed: ${res.status}`);
}

export async function postState(
  conversationId: string,
  state: { isPinned?: boolean; isMuted?: boolean; isFolded?: boolean; isDeleted?: boolean; note?: string | null },
): Promise<void> {
  const res = await authenticatedFetch(`/api/im/conversations/${encodeURIComponent(conversationId)}/state`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(state),
  });
  if (!res.ok) throw new Error(`im state failed: ${res.status}`);
}

// MARK: - Blacklist (server-synced project paths)

export async function fetchBlacklist(): Promise<string[]> {
  const res = await authenticatedFetch('/api/im/blacklist');
  if (!res.ok) throw new Error(`im blacklist fetch failed: ${res.status}`);
  const json = (await res.json()) as { paths?: string[] };
  return json.paths ?? [];
}

export async function postBlacklist(path: string): Promise<string[]> {
  const res = await authenticatedFetch('/api/im/blacklist', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path }),
  });
  if (!res.ok) throw new Error(`im blacklist add failed: ${res.status}`);
  return ((await res.json()) as { paths?: string[] }).paths ?? [];
}

export async function deleteBlacklist(path: string): Promise<string[]> {
  const res = await authenticatedFetch('/api/im/blacklist', {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path }),
  });
  if (!res.ok) throw new Error(`im blacklist remove failed: ${res.status}`);
  return ((await res.json()) as { paths?: string[] }).paths ?? [];
}

// MARK: - Usage limits + per-conversation context occupancy (read-only displays)

/** One rolling-window utilization sample (5h or 7d). `null` when unavailable. */
export interface ClaudeUsageWindow {
  /** 0–100. */
  utilizationPct: number;
  /** RFC3339 timestamp when the window resets. */
  resetsAt: string;
}

export interface ClaudeUsageLimits {
  fiveHour: ClaudeUsageWindow | null;
  sevenDay: ClaudeUsageWindow | null;
  /** ms epoch when the server last fetched these limits from upstream. */
  asOf?: number;
}

/** Context-window occupancy for one conversation. `null` when unknown. */
export interface ConversationContext {
  contextTokens: number;
  windowTokens: number;
  /** 0–100. */
  pct: number;
}

/**
 * GET /api/usage/claude-limits — always 200; either window field may be null.
 * Returns both windows null on any transport/parse failure so callers can stay
 * null-safe without try/catch. Pass `force` for a manual refresh (the server
 * still throttles actual upstream calls to once per 5 minutes).
 */
export async function fetchClaudeUsageLimits(force = false): Promise<ClaudeUsageLimits> {
  try {
    const res = await authenticatedFetch(`/api/usage/claude-limits${force ? '?force=1' : ''}`);
    if (!res.ok) return { fiveHour: null, sevenDay: null };
    const json = (await res.json()) as Partial<ClaudeUsageLimits> | null;
    return {
      fiveHour: json?.fiveHour ?? null,
      sevenDay: json?.sevenDay ?? null,
      asOf: typeof json?.asOf === 'number' ? json.asOf : undefined,
    };
  } catch {
    return { fiveHour: null, sevenDay: null };
  }
}

/** Network round-trip from the hub to api.anthropic.com (the Claude server),
 *  routed through the hub's proxy. Distinct from the client↔hub WS latency:
 *  the client can't reach api.anthropic.com directly (geo-blocked in CN), so
 *  the hub measures it. null on transport failure. */
export interface ClaudePing {
  ms: number | null;
  ok: boolean;
  via: 'proxy' | 'direct';
}

export async function fetchClaudePing(): Promise<ClaudePing | null> {
  try {
    const res = await authenticatedFetch('/api/usage/claude-ping');
    if (!res.ok) return null;
    return (await res.json()) as ClaudePing;
  } catch {
    return null;
  }
}

/**
 * GET /api/im/conversations/<id>/context — 200 with the occupancy object OR
 * `null`. Returns null on any failure so callers render nothing.
 */
export async function fetchConversationContext(
  conversationId: string,
): Promise<ConversationContext | null> {
  try {
    const res = await authenticatedFetch(
      `/api/im/conversations/${encodeURIComponent(conversationId)}/context`,
    );
    if (!res.ok) return null;
    const json = (await res.json()) as Partial<ConversationContext> | null;
    if (
      !json ||
      typeof json.contextTokens !== 'number' ||
      typeof json.windowTokens !== 'number' ||
      typeof json.pct !== 'number'
    ) {
      return null;
    }
    return {
      contextTokens: json.contextTokens,
      windowTokens: json.windowTokens,
      pct: json.pct,
    };
  } catch {
    return null;
  }
}
