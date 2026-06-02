import { promises as fs } from 'fs';

import { Router } from 'express';

import {
  recordUserMessage,
  recordAssistantMessage,
  recordImageMessage,
  isSdkTurnActive,
} from '../services/im-record.service.js';
import { distillJsonl } from '../services/im-distill.service.js';
import { saveImageFromPath } from '../services/im-media.service.js';
import { registerTerminalChoice, getTerminalChoiceDecision } from '../claude-sdk.js';
import { sessionsDb } from '../modules/database/index.js';

/**
 * The contact id == the session's PROJECT ROOT (the dir its jsonl lives in, which
 * `resume` needs as cwd). A hook's `cwd` can have wandered into a subdir (the
 * user `cd`'d mid-session), so prefer the watcher-recorded `sessions.project_path`
 * and fall back to the hook's cwd only when the session isn't indexed yet.
 */
function resolveContactId(sessionId, fallbackProjectPath) {
  try {
    const root = sessionsDb.getSessionById(sessionId)?.project_path;
    if (typeof root === 'string' && root.length > 0) return root;
  } catch {
    /* best-effort */
  }
  return typeof fallbackProjectPath === 'string' && fallbackProjectPath.length > 0 ? fallbackProjectPath : null;
}

/**
 * Hook ingest endpoint (Phase 2) — terminal / IDE Claude sessions.
 *
 * Claude sessions run directly in a terminal (NOT via the IM app/SDK) fire the
 * `settings.json` UserPromptSubmit / Stop hooks. A tiny in-repo hook script
 * (scripts/im-claude-hook.mjs) POSTs those turn-boundary events here so terminal
 * sessions also land in the IM hub — same authoritative `imDb` recording the SDK
 * path uses, just driven by an external process instead of in-process.
 *
 * AUTH MODEL — this router is mounted OUTSIDE the JWT `authenticateToken`
 * middleware (hooks carry no JWT). It enforces its own gate:
 *   (a) loopback only — the request's remote address must be 127.0.0.1 / ::1 /
 *       ::ffff:127.0.0.1 (the hook always POSTs to 127.0.0.1); and
 *   (b) if `process.env.IM_HOOK_TOKEN` is set, the `X-IM-Hook-Token` header must
 *       match it, else 403.
 *
 * DEDUP — `settingSources` includes user/project/local, so a settings hook ALSO
 * fires for SDK (app) sessions, which P1 already records in-process. To avoid
 * double-recording we SKIP any event whose session has an in-flight (or
 * just-finished) SDK turn (`isSdkTurnActive`). As a backstop, `imDb.insertMessages`
 * is idempotent on `(conversation_id, source_id)`, so even a racing duplicate
 * collapses to one row.
 *
 * The endpoint ALWAYS responds `200 {ok:true}` (even on skip / no-op / non-fatal
 * parse issues) so the hook never blocks or fails a Claude run.
 */

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

function isLoopbackRequest(req) {
  const addr = req.socket?.remoteAddress ?? req.connection?.remoteAddress ?? '';
  return LOOPBACK.has(addr);
}

/**
 * Read the LAST assistant turn out of a transcript jsonl by reusing the same
 * `distillJsonl` the file watcher uses, and pick its final `result` | `error`
 * message. The distilled assistant sourceId is the turn's first assistant uuid —
 * the SAME key a later watcher / SDK pass keys on, so this dedups against it.
 */
async function readLastAssistantTurn(transcriptPath) {
  if (typeof transcriptPath !== 'string' || transcriptPath.length === 0) return null;
  let raw;
  try {
    raw = await fs.readFile(transcriptPath, 'utf8');
  } catch {
    return null; // transcript missing / unreadable — nothing to record
  }
  const entries = [];
  for (const line of raw.split('\n')) {
    const text = line.trim();
    if (!text) continue;
    try {
      entries.push(JSON.parse(text));
    } catch {
      // skip malformed / partially-written line
    }
  }
  const distilled = distillJsonl(entries);
  for (let i = distilled.length - 1; i >= 0; i--) {
    const m = distilled[i];
    if (m.kind === 'result' || m.kind === 'error') return m;
  }
  return null;
}

function handleUser(body) {
  const { sessionId, projectPath, content } = body;
  if (typeof sessionId !== 'string' || !sessionId) return;
  if (typeof content !== 'string' || !content.trim()) return;
  if (isSdkTurnActive(sessionId)) return; // SDK path owns this session's recording

  recordUserMessage({
    sessionId,
    contactId: resolveContactId(sessionId, projectPath),
    title: null,
    content,
    // No clientMsgId from a terminal — recordUserMessage derives a stable
    // sourceId from sessionId + timestamp so a re-fire collapses to one row.
    clientMsgId: null,
    // Backstop for the new-app-session race: if the SDK path already recorded
    // this exact prompt (under its clientMsgId) within the last 15s, skip — the
    // isSdkTurnActive gate above catches the common case; this covers the sliver
    // where the hook's POST beats the SDK setting the gate on a brand-new id.
    dedupeWindowMs: 15_000,
  });
}

async function handleStop(body) {
  const { sessionId, projectPath, transcriptPath } = body;
  if (typeof sessionId !== 'string' || !sessionId) return;
  if (isSdkTurnActive(sessionId)) return; // SDK path owns this session's recording

  const turn = await readLastAssistantTurn(transcriptPath);
  if (!turn) return;

  recordAssistantMessage({
    sessionId,
    contactId: resolveContactId(sessionId, projectPath),
    title: null,
    content: turn.content,
    sourceId: turn.sourceId, // = first assistant uuid → dedups vs watcher/SDK
    createdAt: turn.createdAt || Date.now(),
    isError: turn.kind === 'error',
    toolCount: turn.toolTrace?.count ?? 0,
    rawRefStart: turn.toolTrace?.rawRefStart ?? null,
    rawRefEnd: turn.toolTrace?.rawRefEnd ?? null,
  });
}

const router = Router();

// Gate: loopback only + optional shared token.
router.use((req, res, next) => {
  if (!isLoopbackRequest(req)) {
    return res.status(403).json({ ok: false, error: 'forbidden' });
  }
  const expected = process.env.IM_HOOK_TOKEN;
  if (typeof expected === 'string' && expected.length > 0) {
    if (req.get('X-IM-Hook-Token') !== expected) {
      return res.status(403).json({ ok: false, error: 'forbidden' });
    }
  }
  next();
});

// POST /api/im-hook/image — assistant-sent image (e.g. a test-result screenshot)
// from scripts/im-send-image.mjs. The body carries an ABSOLUTE path on this same
// machine; the media service validates + copies it into the managed store and we
// record a kind:'image' bubble. Unlike /ingest this is NOT gated on
// isSdkTurnActive — sending an image is an explicit, standalone action. Returns
// the mediaId so the CLI can confirm. 400 on a bad/oversized/non-image file.
router.post('/image', (req, res) => {
  const { sessionId, projectPath, imagePath, caption } = req.body ?? {};
  if (typeof sessionId !== 'string' || !sessionId) {
    return res.status(400).json({ ok: false, error: 'missing sessionId' });
  }
  let saved;
  try {
    saved = saveImageFromPath(imagePath);
  } catch (err) {
    return res.status(400).json({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
  recordImageMessage({
    sessionId,
    contactId: resolveContactId(sessionId, projectPath),
    title: null,
    mediaId: saved.id,
    caption: typeof caption === 'string' ? caption : undefined,
    bytes: saved.bytes,
  });
  res.json({ ok: true, mediaId: saved.id });
});

// POST /api/im-hook/choice — a TERMINAL Claude session hit AskUserQuestion /
// ExitPlanMode. The blocking PreToolUse hook (scripts/im-claude-choice-hook.mjs)
// registers the question here (records + broadcasts a 红包-style choice card) and
// then polls GET /choice/:requestId for the user's answer. App (SDK) sessions are
// handled in-process by the SDK's own PreToolUse hook, so we DEFER (skip) those
// — signalled by `isSdkTurnActive` — to avoid a double card / conflicting answer.
router.post('/choice', (req, res) => {
  const { sessionId, projectPath, requestId, toolName, input } = req.body ?? {};
  if (typeof sessionId !== 'string' || !sessionId || typeof requestId !== 'string' || !requestId) {
    return res.status(400).json({ ok: false, error: 'missing sessionId/requestId' });
  }
  if (toolName !== 'AskUserQuestion' && toolName !== 'ExitPlanMode') {
    return res.status(400).json({ ok: false, error: 'unsupported toolName' });
  }
  if (isSdkTurnActive(sessionId)) {
    return res.json({ ok: true, skip: true });
  }
  registerTerminalChoice({
    requestId,
    sessionId,
    contactId: resolveContactId(sessionId, projectPath),
    title: null,
    toolName,
    input: input && typeof input === 'object' ? input : {},
  });
  res.json({ ok: true });
});

// GET /api/im-hook/choice/:requestId — poll target for the choice hook.
router.get('/choice/:requestId', (req, res) => {
  res.json(getTerminalChoiceDecision(req.params.requestId));
});

router.post('/ingest', async (req, res) => {
  // ALWAYS 200 so the hook never blocks Claude; log + swallow non-fatal errors.
  try {
    const body = req.body ?? {};
    if (body.event === 'user') {
      handleUser(body);
    } else if (body.event === 'stop') {
      await handleStop(body);
    }
  } catch (err) {
    console.error('IM hook ingest failed', err instanceof Error ? err.message : String(err));
  }
  res.json({ ok: true });
});

export default router;
