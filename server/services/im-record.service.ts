import { imDb } from '@/modules/database/index.js';
import { buildImMessageEvent, broadcastImEvent } from '@/services/im-events.service.js';
import type { DistilledMessage } from '@/shared/types.js';

/**
 * Authoritative IM recording from the SDK chat runtime (Phase 1).
 *
 * Instead of reverse-engineering IM bubbles from the Claude jsonl via the file
 * watcher (which re-broadcast a growing assistant `result` on EVERY jsonl append
 * during a turn — the "streaming" lag root cause), the SDK path now records the
 * two real turn-boundary messages directly:
 *   - the USER message the instant `queryClaudeSDK` accepts a real prompt, and
 *   - the ASSISTANT message ONCE at turn completion.
 *
 * Both go through `imDb.insertMessages`, which is idempotent on
 * (conversation_id, source_id) and assigns a monotonic per-conversation seq, so
 * a later watcher pass (startup backfill) over the same jsonl dedups instead of
 * double-inserting.
 *
 * De-streaming strategy: an ACTIVE-SESSION GATE (see the turn registry below).
 * SourceId alignment alone is insufficient for the USER bubble — at send time we
 * only know `clientMsgId`, not the jsonl user-entry uuid that `distillJsonl`
 * would key on, so the watcher's distilled user row would carry a DIFFERENT
 * sourceId and duplicate. The assistant sourceId IS alignable (we capture the
 * turn's first assistant uuid from the SDK stream, the same key distill uses),
 * but to keep the rule uniform and bullet-proof we simply suppress the watcher's
 * live re-broadcast for any session with an in-flight SDK turn. Startup backfill
 * (sessions that are NOT in an active turn) still flows through the watcher /
 * `backfillRecentSessions` as before, so history is unaffected.
 */

// Sessions the SDK path is (or was very recently) authoritatively recording.
// While a session is gated the file watcher MUST NOT broadcast distilled
// messages for it.
//
// `0` = an in-flight turn (open-ended gate). A positive value = a grace
// DEADLINE (epoch ms) after turn completion: the watcher's jsonl write is
// debounced and lands AFTER our `kind:'complete'` recording, and `distillJsonl`
// keys the USER bubble on the jsonl user-entry uuid — which differs from our
// `clientMsgId` sourceId — so without a grace window that late pass would insert
// a DUPLICATE user bubble. The grace window swallows that trailing pass. The
// assistant bubble is already sourceId-aligned (we use the turn's first
// assistant uuid, the same key distill uses) so it dedups regardless.
const sdkTurnGate = new Map<string, number>();
const TURN_GRACE_MS = 5_000;

/** Mark a session as having an in-flight SDK turn (open-ended gate). */
export function beginSdkTurn(sessionId: string): void {
  if (sessionId) sdkTurnGate.set(sessionId, 0);
}

/** End the in-flight turn but keep a short grace gate so the watcher's trailing
 *  debounced jsonl pass for THIS turn is still suppressed. */
export function endSdkTurn(sessionId: string, now: number = Date.now()): void {
  if (sessionId) sdkTurnGate.set(sessionId, now + TURN_GRACE_MS);
}

/** True while the SDK path owns (or just owned) a turn for this session. */
export function isSdkTurnActive(sessionId: string, now: number = Date.now()): boolean {
  const deadline = sdkTurnGate.get(sessionId);
  if (deadline === undefined) return false;
  if (deadline === 0) return true; // in-flight
  if (now < deadline) return true; // within grace window
  sdkTurnGate.delete(sessionId); // grace expired — let the watcher resume
  return false;
}

/** Test hook: clear the active-turn registry between tests. */
export function __resetSdkTurns(): void {
  sdkTurnGate.clear();
}

export interface RecordUserOptions {
  sessionId: string;
  /** The project path / cwd — mirrors how ingest seeds the conversation contact. */
  contactId: string | null;
  /** Conversation title; null leaves any existing title untouched (COALESCE). */
  title: string | null;
  /** The ORIGINAL user text (before image-path injection). */
  content: string;
  /** Idempotency key from the send path; falls back to a derived stable id. */
  clientMsgId?: string | null;
  createdAt?: number;
  /**
   * When > 0, skip recording if an identical-content user message already exists
   * in this conversation within the last `dedupeWindowMs`. Set ONLY by the
   * terminal hook: on a brand-new app session the SDK records the user bubble
   * (keyed by clientMsgId) just before the hook's POST arrives, and the hook
   * would re-key the same text under a different sourceId. The SDK path leaves
   * this unset so legitimately-repeated prompts are never collapsed.
   */
  dedupeWindowMs?: number;
}

/**
 * Record the authoritative USER message for a send and broadcast it once.
 * sourceId = clientMsgId when present (the same key the send path dedups on),
 * else a stable id derived from the content + timestamp so a resend without a
 * clientMsgId still collapses to one row. Returns the inserted row count.
 */
export function recordUserMessage(opts: RecordUserOptions): number {
  const content = opts.content.trim();
  if (!content) return 0;

  // Hook backstop: drop a user message the SDK path already recorded under a
  // different sourceId within the dedup window (sourceId-agnostic).
  if (typeof opts.dedupeWindowMs === 'number' && opts.dedupeWindowMs > 0) {
    if (imDb.hasRecentUserMessage(opts.sessionId, content, Date.now() - opts.dedupeWindowMs)) {
      return 0;
    }
  }

  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);

  const createdAt = opts.createdAt ?? Date.now();
  const sourceId =
    typeof opts.clientMsgId === 'string' && opts.clientMsgId.length > 0
      ? opts.clientMsgId
      : `user-send:${opts.sessionId}:${createdAt}`;

  const msg: DistilledMessage = {
    sourceId,
    role: 'user',
    kind: 'text',
    content,
    createdAt,
  };
  const affected = imDb.insertMessages(opts.sessionId, [msg]);
  for (const row of affected) broadcastImEvent(buildImMessageEvent(row));
  return affected.length;
}

// ── Interactive choice cards (AskUserQuestion / ExitPlanMode) ──────────────────
//
// These are the ONE thing recorded + broadcast MID-TURN (the spec's exception to
// "no message body during a turn"): Claude is blocked waiting for the user, so
// the card must appear immediately on every device, and is also recorded so it
// shows up in /sync history. The card content is a small JSON string parsed
// whole by clients (serializeMessage exempts kind:'choice' from truncation).
//
// sourceId = `choice:<requestId>` is stable, so resolving the card re-records
// with the SAME sourceId — insertMessages UPSERTs in place (content changed →
// re-broadcast), flipping the card from pending to answered on every device.

export interface ChoiceQuestionOption {
  label: string;
  description?: string;
}
export interface ChoiceQuestion {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options: ChoiceQuestionOption[];
}

/** Pending-card content schema (kind:'choice'). `answered` is absent/false. */
export interface ChoiceCardContent {
  requestId: string;
  toolName: 'AskUserQuestion' | 'ExitPlanMode';
  /** Present for AskUserQuestion. */
  questions?: ChoiceQuestion[];
  /** Present for ExitPlanMode (the plan text from the tool input). */
  plan?: string;
  /** Terminal state: set once the user answers / approves / it is cancelled. */
  answered?: boolean;
  /** Human summary of what was chosen, e.g. "已选择 Red" / "已同意" / "已取消". */
  answer?: string;
}

export interface RecordChoiceCardOptions {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  requestId: string;
  toolName: 'AskUserQuestion' | 'ExitPlanMode';
  questions?: ChoiceQuestion[];
  plan?: string;
  createdAt?: number;
}

function choiceSourceId(requestId: string): string {
  return `choice:${requestId}`;
}

function writeChoiceMessage(
  opts: { sessionId: string; contactId: string | null; title: string | null; createdAt?: number },
  card: ChoiceCardContent,
): number {
  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);
  const msg: DistilledMessage = {
    sourceId: choiceSourceId(card.requestId),
    role: 'assistant',
    kind: 'choice',
    content: JSON.stringify(card),
    createdAt: opts.createdAt ?? Date.now(),
  };
  const affected = imDb.insertMessages(opts.sessionId, [msg]);
  for (const row of affected) broadcastImEvent(buildImMessageEvent(row));
  return affected.length;
}

/** Record + live-broadcast a PENDING interactive choice card. */
export function recordChoiceCard(opts: RecordChoiceCardOptions): number {
  const card: ChoiceCardContent = {
    requestId: opts.requestId,
    toolName: opts.toolName,
  };
  if (opts.toolName === 'ExitPlanMode') {
    card.plan = typeof opts.plan === 'string' ? opts.plan : '';
  } else {
    card.questions = Array.isArray(opts.questions) ? opts.questions : [];
  }
  return writeChoiceMessage(opts, card);
}

/**
 * Flip an existing choice card to its terminal (answered/cancelled) state and
 * re-broadcast. Same sourceId → in-place UPSERT. `answer` is the summary shown
 * on the card (e.g. "已选择 Red, Blue", "已同意", "已取消"). Returns affected count.
 */
export function resolveChoiceCard(opts: {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  requestId: string;
  toolName: 'AskUserQuestion' | 'ExitPlanMode';
  questions?: ChoiceQuestion[];
  plan?: string;
  answer: string;
  createdAt?: number;
}): number {
  const card: ChoiceCardContent = {
    requestId: opts.requestId,
    toolName: opts.toolName,
    answered: true,
    answer: opts.answer,
  };
  if (opts.toolName === 'ExitPlanMode') {
    card.plan = typeof opts.plan === 'string' ? opts.plan : '';
  } else {
    card.questions = Array.isArray(opts.questions) ? opts.questions : [];
  }
  return writeChoiceMessage(opts, card);
}

// ── Assistant-sent images ─────────────────────────────────────────────────────
//
// An image bubble (kind:'image'). Content is a small JSON `{mediaId, caption}`;
// clients fetch the bytes from GET /api/im/media/:mediaId. sourceId =
// `image:<mediaId>` is stable, so re-sending the same stored image collapses.
// serializeMessage exempts kind:'image' from truncation (the JSON is tiny).

export interface RecordImageOptions {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  /** `<hex>.<ext>` media id returned by im-media.service saveImageFromPath. */
  mediaId: string;
  caption?: string;
  /** Original (full-res) byte size — shown on the "查看原图 (N MB)" affordance. */
  bytes?: number;
  createdAt?: number;
}

export function recordImageMessage(opts: RecordImageOptions): number {
  if (typeof opts.mediaId !== 'string' || opts.mediaId.length === 0) return 0;

  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);

  const msg: DistilledMessage = {
    sourceId: `image:${opts.mediaId}`,
    role: 'assistant',
    kind: 'image',
    content: JSON.stringify({
      mediaId: opts.mediaId,
      caption: opts.caption ?? '',
      ...(typeof opts.bytes === 'number' && opts.bytes > 0 ? { bytes: opts.bytes } : {}),
    }),
    createdAt: opts.createdAt ?? Date.now(),
  };
  const affected = imDb.insertMessages(opts.sessionId, [msg]);
  for (const row of affected) broadcastImEvent(buildImMessageEvent(row));
  return affected.length;
}

export interface RecordAssistantOptions {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  content: string;
  /**
   * Stable id for the assistant bubble. Pass the turn's FIRST assistant entry
   * uuid when available — this is the SAME key `distillJsonl` uses, so a later
   * watcher pass over the jsonl dedups against this row instead of duplicating.
   * Falls back to a derived per-session id.
   */
  sourceId?: string | null;
  createdAt?: number;
  /** true → record kind 'error' (the turn ended in an error completion). */
  isError?: boolean;
  /** Tool-operation count for the collapsed gray bar (optional). */
  toolCount?: number;
  rawRefStart?: string | null;
  rawRefEnd?: string | null;
}

/**
 * Record the ONE assistant message at turn completion and broadcast it once.
 * Skips empty, non-error turns (a tools-only turn with no concluding text and
 * no error has nothing to show). Returns the inserted/updated row count.
 */
export function recordAssistantMessage(opts: RecordAssistantOptions): number {
  const content = opts.content.trim();
  const isError = opts.isError === true;
  const toolCount = opts.toolCount ?? 0;
  if (!content && !isError && toolCount === 0) return 0;

  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);

  const createdAt = opts.createdAt ?? Date.now();
  const sourceId =
    typeof opts.sourceId === 'string' && opts.sourceId.length > 0
      ? opts.sourceId
      : `asst-turn:${opts.sessionId}:${createdAt}`;

  const msg: DistilledMessage = {
    sourceId,
    role: 'assistant',
    kind: isError ? 'error' : 'result',
    content,
    createdAt,
  };
  if (toolCount > 0 && opts.rawRefStart && opts.rawRefEnd) {
    msg.toolTrace = { count: toolCount, rawRefStart: opts.rawRefStart, rawRefEnd: opts.rawRefEnd };
  }
  const affected = imDb.insertMessages(opts.sessionId, [msg]);
  for (const row of affected) broadcastImEvent(buildImMessageEvent(row));
  return affected.length;
}
