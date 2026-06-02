import { Router } from 'express';

import { queryClaudeSDK, resolveInteractiveAnswer } from '../claude-sdk.js';
import { imDb, sessionsDb } from '../modules/database/index.js';
import { serializeMessage, buildImReadEvent, buildImPokeEvent, broadcastImEvent } from '../services/im-events.service.js';
import { readTranscriptPage, readTranscriptBlob } from '../services/im-transcript.service.js';
import { getConversationContext } from '../services/context-usage.service.js';
import { resolveMedia } from '../services/im-media.service.js';

const router = Router();

// No-op writer satisfying the interface queryClaudeSDK expects from its `ws`
// arg (a WebSocketWriter): `.send()`, `.setSessionId()`, `.getSessionId()`,
// `.updateWebSocket()`, plus a `.userId` field. The Apple Watch can't hold a
// WebSocket, so it can't stream; it polls /api/im/sync instead. Streamed frames
// are simply dropped here — the assistant reply still lands in the IM hub via
// the jsonl file-watcher, which the watch picks up on its next sync.
function createNoopWriter() {
  return {
    isWebSocketWriter: true,
    userId: null,
    sessionId: null,
    send() {},
    setSessionId(sessionId) {
      this.sessionId = sessionId;
    },
    getSessionId() {
      return this.sessionId;
    },
    updateWebSocket() {},
  };
}

// conversation id == session id; resolve the raw jsonl path for the full-record viewer.
function jsonlPathForConversation(conversationId) {
  return sessionsDb.getSessionById(conversationId)?.jsonl_path ?? null;
}

const SYNC_PAGE = 200;

// Parse an integer query param, honoring an explicit 0 (unlike `parseInt(x) || dflt`).
function intParam(value, dflt) {
  if (value === undefined) return dflt;
  const n = Number.parseInt(String(value), 10);
  return Number.isFinite(n) ? n : dflt;
}

// The stored preview is a raw substring of the newest message content, so a
// structured (JSON) message — an image or a choice card — would show its raw
// JSON in the conversation list. Map those to a friendly label.
function previewLabel(preview) {
  if (typeof preview !== 'string') return preview;
  const t = preview.trimStart();
  if (t.startsWith('{"mediaId"')) {
    try {
      const o = JSON.parse(preview);
      if (o && o.mediaId) return o.caption ? `[图片] ${o.caption}` : '[图片]';
    } catch {
      /* truncated JSON — fall through to the generic label */
    }
    return '[图片]';
  }
  if (t.startsWith('{"requestId"')) return '[卡片]';
  return preview;
}

function serializeConversation(c) {
  return {
    id: c.id,
    contactId: c.contact_id,
    providerId: c.provider_id,
    title: c.title,
    lastMessagePreview: previewLabel(c.last_message_preview),
    lastSeq: c.last_seq,
    lastActivityAt: c.last_activity_at,
    isPinned: !!c.is_pinned,
    isMuted: !!c.is_muted,
    note: c.note ?? null,
    isFolded: !!c.is_folded,
    isDeleted: !!c.is_deleted,
  };
}

// GET /api/im/sync?since=<cursor> — incremental sync of messages + conversations + read cursors.
// GET /api/im/sync?recent=<N> — cold-start cap: only the last N messages per
// conversation, with the cursor set to the current max rev (skips downloading
// thousands of old messages; older history is lazy-loaded per conversation).
router.get('/sync', (req, res) => {
  const since = Number.parseInt(String(req.query.since ?? '0'), 10) || 0;
  const recent = Number.parseInt(String(req.query.recent ?? '0'), 10) || 0;
  let rows;
  let cursor;
  let hasMore;
  if (recent > 0 && since === 0) {
    rows = imDb.getRecentMessagesPerConversation(recent);
    cursor = imDb.getMaxRev();
    hasMore = false;
  } else {
    ({ rows, cursor, hasMore } = imDb.getMessagesSince(since, SYNC_PAGE));
  }
  res.json({
    messages: rows.map(serializeMessage),
    conversations: imDb.listConversations().map(serializeConversation),
    readCursors: imDb.getReadCursors().map((r) => ({
      conversationId: r.conversation_id,
      deviceId: r.device_id,
      lastReadSeq: r.last_read_seq,
    })),
    cursor,
    hasMore,
  });
});

// GET /api/im/conversations — list only.
router.get('/conversations', (_req, res) => {
  res.json({ conversations: imDb.listConversations().map(serializeConversation) });
});

// GET /api/im/conversations/:id/messages?anchor=&numBefore=&numAfter=
router.get('/conversations/:id/messages', (req, res) => {
  const anchor = req.query.anchor !== undefined ? Number.parseInt(String(req.query.anchor), 10) : undefined;
  const numBefore = intParam(req.query.numBefore, 40);
  const numAfter = intParam(req.query.numAfter, 0);
  const rows = imDb.listMessages(req.params.id, { anchorSeq: anchor, numBefore, numAfter });
  res.json({ messages: rows.map(serializeMessage) });
});

// GET /api/im/conversations/:conversationId/messages/:messageId/content
// Lazy full-text for long messages: /sync and im:message frames carry a
// truncated preview (see serializeMessage); the client fetches the full body on
// demand. `messageId` is the serialized message `id` (== source_id).
router.get('/conversations/:conversationId/messages/:messageId/content', (req, res) => {
  const content = imDb.getMessageContent(req.params.conversationId, req.params.messageId);
  if (content === null) {
    return res.status(404).json({ error: 'message not found' });
  }
  return res.json({ content });
});

// GET /api/im/media/:id — bytes of an assistant-sent image (kind:'image').
// `:id` is the `<hex>.<ext>` media id from the message content; resolveMedia
// rejects any other shape, so only files we stored can ever be served.
router.get('/media/:id', (req, res) => {
  const wantThumb = req.query.thumb === '1';
  const media = resolveMedia(req.params.id, wantThumb);
  if (!media) {
    return res.status(404).json({ error: 'media not found' });
  }
  res.setHeader('Content-Type', media.contentType);
  res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
  return res.sendFile(media.absPath);
});

// POST /api/im/conversations/:id/read  { deviceId, lastReadSeq }
router.post('/conversations/:id/read', (req, res) => {
  const { deviceId, lastReadSeq } = req.body ?? {};
  if (typeof deviceId !== 'string' || typeof lastReadSeq !== 'number') {
    return res.status(400).json({ error: 'deviceId (string) and lastReadSeq (number) required' });
  }
  imDb.setReadCursor(req.params.id, deviceId, lastReadSeq);
  broadcastImEvent(buildImReadEvent(req.params.id, deviceId, lastReadSeq));
  return res.json({ ok: true });
});

// POST /api/im/conversations/:id/state  { isPinned?, isMuted?, isFolded?, isDeleted?, note? }
// All per-conversation meta is server-synced so every client agrees. Changing it
// pokes other clients to re-pull the (always-full) conversation list.
router.post('/conversations/:id/state', (req, res) => {
  const { isPinned, isMuted, isFolded, isDeleted, note } = req.body ?? {};
  imDb.setConversationState(req.params.id, { isPinned, isMuted, isFolded, isDeleted, note });
  broadcastImEvent(buildImPokeEvent(0));
  return res.json({ ok: true });
});

// GET /api/im/blacklist — server-synced blacklisted project paths.
router.get('/blacklist', (_req, res) => {
  res.json({ paths: imDb.listBlacklist() });
});

// POST /api/im/blacklist  { path }   — add a path to the blacklist.
router.post('/blacklist', (req, res) => {
  const path = typeof req.body?.path === 'string' ? req.body.path : '';
  if (!path.trim()) return res.status(400).json({ error: 'path (string) required' });
  imDb.addBlacklist(path, Date.now());
  broadcastImEvent(buildImPokeEvent(0));
  return res.json({ ok: true, paths: imDb.listBlacklist() });
});

// DELETE /api/im/blacklist  { path }  — remove a path from the blacklist.
router.delete('/blacklist', (req, res) => {
  const path = typeof req.body?.path === 'string' ? req.body.path : '';
  if (!path.trim()) return res.status(400).json({ error: 'path (string) required' });
  imDb.removeBlacklist(path);
  broadcastImEvent(buildImPokeEvent(0));
  return res.json({ ok: true, paths: imDb.listBlacklist() });
});

// GET /api/im/conversations/:id/context — per-conversation context-window
// occupancy (contextTokens / windowTokens / pct), computed from the session
// jsonl. Reuses the same jsonl-locating logic as the transcript routes.
// Returns 200 with `null` when there is no usage data yet (graceful degrade).
router.get('/conversations/:id/context', async (req, res) => {
  const jsonlPath = jsonlPathForConversation(req.params.id);
  const context = await getConversationContext(jsonlPath);
  return res.json(context);
});

// GET /api/im/conversations/:id/transcript?anchor=&numBefore=&numAfter=
// Full raw record (tools/thinking) — paginated, summaries only; fetch big blobs lazily.
router.get('/conversations/:id/transcript', async (req, res) => {
  const jsonlPath = jsonlPathForConversation(req.params.id);
  if (!jsonlPath) {
    return res.status(404).json({ error: 'transcript not found' });
  }
  const anchor = req.query.anchor !== undefined ? String(req.query.anchor) : undefined;
  // No anchor → first page from the top (numAfter walks forward); with an anchor,
  // the client passes numBefore to scroll up. Default to a non-empty first page.
  const numBefore = intParam(req.query.numBefore, 0);
  const numAfter = intParam(req.query.numAfter, 40);
  const page = await readTranscriptPage({ jsonlPath, anchor, numBefore, numAfter });
  return res.json(page);
});

// GET /api/im/conversations/:id/transcript/blob/:entryId — full payload of one raw entry.
router.get('/conversations/:id/transcript/blob/:entryId', async (req, res) => {
  const jsonlPath = jsonlPathForConversation(req.params.id);
  if (!jsonlPath) {
    return res.status(404).json({ error: 'transcript not found' });
  }
  const blob = await readTranscriptBlob(jsonlPath, req.params.entryId);
  if (!blob) {
    return res.status(404).json({ error: 'entry not found' });
  }
  return res.json({ entry: blob });
});

// POST /api/im/conversations/:conversationId/send  { text, projectPath }
// Plain-HTTP send path for the Apple Watch, which can't open a WebSocket
// (watchOS forbids low-level networking). Mirrors the WS `claude-command`
// frame: kicks off the same queryClaudeSDK work, then returns 202 immediately
// without awaiting the generation. The reply reaches the hub via the jsonl
// file-watcher and the watch polls /api/im/sync for it.
router.post('/conversations/:conversationId/send', (req, res) => {
  const { text, projectPath, clientMsgId } = req.body ?? {};
  if (typeof text !== 'string' || text.trim().length === 0) {
    return res.status(400).json({ error: 'text (non-empty string) required' });
  }

  const conversationId = req.params.conversationId;
  const resolvedProjectPath = typeof projectPath === 'string' ? projectPath : null;

  const options = {
    sessionId: conversationId,
    projectPath: resolvedProjectPath,
    cwd: resolvedProjectPath,
    resume: true,
    permissionMode: 'bypassPermissions',
    // Idempotency key for "reliable send": a resend with the same id is a no-op
    // on the server (server/claude-sdk.js dedup) instead of a second Claude run.
    ...(typeof clientMsgId === 'string' && clientMsgId.length > 0 ? { clientMsgId } : {}),
  };

  // Fire-and-forget: do not await completion so the HTTP response returns now.
  void queryClaudeSDK(text, options, createNoopWriter()).catch((err) => {
    console.error('[ERROR] IM send queryClaudeSDK failed:', err);
  });

  return res.status(202).json({ ok: true });
});

// POST /api/im/conversations/:conversationId/respond
//   { requestId, answers?: { [question]: string[] }, approve?: boolean }
// Plain-HTTP response channel for an interactive choice card, used by the Apple
// Watch (no chat WebSocket). The server reconstructs the tool decision from the
// PENDING approval's STORED input (the watch never saw it) and unblocks Claude
// via resolveToolApproval — the same path the WS `claude-permission-response`
// {answers|approve} shape uses. The card then flips to its terminal state and
// re-broadcasts to every device.
//   - 404 when requestId is unknown / already resolved.
//   - 400 when the payload carries no valid answer for that tool.
router.post('/conversations/:conversationId/respond', (req, res) => {
  const { requestId, answers, approve } = req.body ?? {};
  if (typeof requestId !== 'string' || requestId.length === 0) {
    return res.status(400).json({ error: 'requestId (string) required' });
  }
  const hasAnswer = (answers !== undefined && answers !== null) || typeof approve === 'boolean';
  if (!hasAnswer) {
    return res.status(400).json({ error: 'answers (object) or approve (boolean) required' });
  }

  const result = resolveInteractiveAnswer(requestId, { answers, approve });
  if (!result.ok) {
    if (result.code === 'not_found') {
      return res.status(404).json({ error: 'unknown or already-resolved requestId' });
    }
    return res.status(400).json({ error: 'payload does not match the pending tool' });
  }
  return res.json({ ok: true });
});

export default router;
