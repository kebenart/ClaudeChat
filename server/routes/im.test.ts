import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import Database from 'better-sqlite3';
import express from 'express';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';
import { sessionsDb } from '@/modules/database/repositories/sessions.db.js';
import imRoutes from '@/routes/im.js';
import {
  __registerPendingApprovalForTests,
  registerTerminalChoice,
  resolveInteractiveAnswer,
  getTerminalChoiceDecision,
} from '@/claude-sdk.js';

async function startServer() {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  __setConnectionForTests(db);
  const app = express();
  app.use(express.json());
  app.use('/api/im', imRoutes);
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const port = (server.address() as { port: number }).port;
  return { server, base: `http://127.0.0.1:${port}/api/im` };
}

afterEach(() => {
  __setConnectionForTests(null);
});

test('GET /sync returns messages + conversations since cursor', async () => {
  const { server, base } = await startServer();
  try {
    imDb.ensureConversation('c1', '/repo', 'Conv 1');
    imDb.insertMessages('c1', [
      { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
      { sourceId: 's2', role: 'assistant', kind: 'result', content: 'yo', createdAt: 2 },
    ]);

    const sync = await (await fetch(`${base}/sync?since=0`)).json() as any;
    assert.equal(sync.messages.length, 2);
    assert.equal(sync.messages[0].id, 's1');
    assert.ok(sync.cursor >= 2);
    assert.equal(sync.conversations.length, 1);
    assert.equal(sync.conversations[0].id, 'c1');

    const empty = await (await fetch(`${base}/sync?since=${sync.cursor}`)).json() as any;
    assert.equal(empty.messages.length, 0);
  } finally {
    server.close();
  }
});

test('POST /read updates the cursor; bad body returns 400', async () => {
  const { server, base } = await startServer();
  try {
    imDb.ensureConversation('c1', '/repo', 'Conv 1');
    imDb.insertMessages('c1', [{ sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 }]);

    const ok = await fetch(`${base}/conversations/c1/read`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: 'devA', lastReadSeq: 1 }),
    });
    assert.equal(ok.status, 200);
    assert.equal(imDb.getReadCursors().find((c) => c.device_id === 'devA')?.last_read_seq, 1);

    const bad = await fetch(`${base}/conversations/c1/read`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: 'devA' }),
    });
    assert.equal(bad.status, 400);
  } finally {
    server.close();
  }
});

test('GET /conversations/:id/messages returns the latest page; POST /state toggles pin', async () => {
  const { server, base } = await startServer();
  try {
    imDb.ensureConversation('c1', '/repo', 'Conv 1');
    imDb.insertMessages(
      'c1',
      Array.from({ length: 5 }, (_, i) => ({
        sourceId: `s${i + 1}`, role: 'user', kind: 'text', content: `m${i + 1}`, createdAt: i + 1,
      }))
    );

    const page = await (await fetch(`${base}/conversations/c1/messages?numBefore=2`)).json() as any;
    assert.deepEqual(page.messages.map((m: any) => m.seq), [4, 5]);

    const stateRes = await fetch(`${base}/conversations/c1/state`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ isPinned: true }),
    });
    assert.equal(stateRes.status, 200);
    const conv = imDb.listConversations().find((c) => c.id === 'c1');
    assert.equal(conv?.is_pinned, 1);
  } finally {
    server.close();
  }
});

test('long message: /sync sends a truncated preview + content endpoint returns full body', async () => {
  const { server, base } = await startServer();
  try {
    const longBody = 'y'.repeat(900); // > 800-char preview limit
    imDb.ensureConversation('c1', '/repo', 'Conv 1');
    imDb.insertMessages('c1', [
      { sourceId: 's1', role: 'assistant', kind: 'result', content: longBody, createdAt: 1 },
    ]);

    const sync = await (await fetch(`${base}/sync?since=0`)).json() as any;
    const synced = sync.messages.find((m: any) => m.id === 's1');
    assert.equal(synced.truncated, true);
    assert.equal(synced.fullLength, 900);
    assert.equal(synced.content.length, 800);

    // The full-text endpoint looks up by the SAME id from /sync.
    const full = await (await fetch(`${base}/conversations/c1/messages/${synced.id}/content`)).json() as any;
    assert.equal(full.content, longBody);

    const missing = await fetch(`${base}/conversations/c1/messages/nope/content`);
    assert.equal(missing.status, 404);
  } finally {
    server.close();
  }
});

test('GET /transcript paginates the raw record; /blob fetches one entry; unknown session 404s', async () => {
  const { server, base } = await startServer();
  try {
    const dir = mkdtempSync(join(tmpdir(), 'im-route-tr-'));
    const file = join(dir, 'sess-t.jsonl');
    writeFileSync(
      file,
      [
        JSON.stringify({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'hi' } }),
        JSON.stringify({ type: 'assistant', uuid: 'a1', message: { role: 'assistant', content: [{ type: 'text', text: 'yo' }] } }),
      ].join('\n'),
      'utf8'
    );
    sessionsDb.createSession('sess-t', 'claude', '/tmp/repo', undefined, undefined, undefined, file);

    // No anchor → latest page (numBefore walks back from the end).
    const page = await (await fetch(`${base}/conversations/sess-t/transcript?numBefore=10`)).json() as any;
    assert.equal(page.entries.length, 2);
    assert.equal(page.entries[0].id, 'u1'); // [u1, a1] — chronological within the page

    const blob = await (await fetch(`${base}/conversations/sess-t/transcript/blob/a1`)).json() as any;
    assert.equal(blob.entry.uuid, 'a1');

    const missing = await fetch(`${base}/conversations/does-not-exist/transcript`);
    assert.equal(missing.status, 404);
  } finally {
    server.close();
  }
});

test('POST /respond reconstructs AskUserQuestion updatedInput from stored input and resolves', async () => {
  const { server, base } = await startServer();
  try {
    // Register a pending AskUserQuestion approval (as the live interception does).
    const storedInput = {
      questions: [{ question: 'Pick a color', options: [{ label: 'Red' }, { label: 'Blue' }] }],
    };
    const decisionP = __registerPendingApprovalForTests('req-ask', {
      sessionId: 'c1',
      toolName: 'AskUserQuestion',
      input: storedInput,
    });

    const res = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: 'req-ask', answers: { 'Pick a color': ['Red', 'Blue'] } }),
    });
    assert.equal(res.status, 200);

    const decision = await decisionP as any;
    assert.equal(decision.allow, true);
    // Reconstructed from the STORED input: original questions preserved + folded answers.
    assert.deepEqual(decision.updatedInput.questions, storedInput.questions);
    assert.deepEqual(decision.updatedInput.answers, { 'Pick a color': 'Red, Blue' });
  } finally {
    server.close();
  }
});

test('POST /respond approves ExitPlanMode via approve:true', async () => {
  const { server, base } = await startServer();
  try {
    const decisionP = __registerPendingApprovalForTests('req-plan', {
      sessionId: 'c1',
      toolName: 'ExitPlanMode',
      input: { plan: 'do the thing' },
    });
    const res = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: 'req-plan', approve: true }),
    });
    assert.equal(res.status, 200);
    const decision = await decisionP as any;
    assert.equal(decision.allow, true);
    assert.deepEqual(decision.updatedInput, { plan: 'do the thing' });
  } finally {
    server.close();
  }
});

test('POST /respond denies ExitPlanMode via approve:false', async () => {
  const { server, base } = await startServer();
  try {
    const decisionP = __registerPendingApprovalForTests('req-plan-no', {
      sessionId: 'c1',
      toolName: 'ExitPlanMode',
      input: { plan: 'do the thing' },
    });
    const res = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: 'req-plan-no', approve: false }),
    });
    assert.equal(res.status, 200);
    const decision = await decisionP as any;
    assert.equal(decision.allow, false);
  } finally {
    server.close();
  }
});

test('POST /respond 404s on an unknown requestId and 400s on a missing answer', async () => {
  const { server, base } = await startServer();
  try {
    const notFound = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: 'nope', answers: { q: ['a'] } }),
    });
    assert.equal(notFound.status, 404);

    // Register a pending request, then send a payload with no answer/approve → 400.
    __registerPendingApprovalForTests('req-bad', { sessionId: 'c1', toolName: 'AskUserQuestion', input: {} });
    const badBody = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: 'req-bad' }),
    });
    assert.equal(badBody.status, 400);

    const missingId = await fetch(`${base}/conversations/c1/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { q: ['a'] } }),
    });
    assert.equal(missingId.status, 400);
  } finally {
    server.close();
  }
});

test('terminal choice bridge: register → resolve(AskUserQuestion) → poll yields the PreToolUse allow+updatedInput', async () => {
  const { server } = await startServer();
  try {
    registerTerminalChoice({
      requestId: 'tc-1',
      sessionId: 'sess-tc',
      contactId: '/r',
      title: null,
      toolName: 'AskUserQuestion',
      input: { questions: [{ question: '颜色?', options: [{ label: '红' }, { label: '蓝' }] }] },
    });
    // A choice card was recorded for the session.
    const msgs = imDb.listMessages('sess-tc', { numBefore: 100, numAfter: 0 });
    assert.equal(msgs.some((m) => m.kind === 'choice'), true);
    assert.deepEqual(getTerminalChoiceDecision('tc-1'), { found: true, answered: false });

    const r = resolveInteractiveAnswer('tc-1', { answers: { '颜色?': ['红'] } });
    assert.deepEqual(r, { ok: true });

    const d = getTerminalChoiceDecision('tc-1') as any;
    assert.equal(d.answered, true);
    assert.equal(d.decision.allow, true);
    assert.equal(d.decision.updatedInput.answers['颜色?'], '红');
    // The entry is consumed after the answered decision is read.
    assert.deepEqual(getTerminalChoiceDecision('tc-1'), { found: false });
  } finally {
    server.close();
  }
});

test('terminal choice bridge: ExitPlanMode approve:false denies', async () => {
  const { server } = await startServer();
  try {
    registerTerminalChoice({
      requestId: 'tc-2',
      sessionId: 'sess-tc2',
      contactId: null,
      title: null,
      toolName: 'ExitPlanMode',
      input: { plan: 'do X' },
    });
    assert.deepEqual(resolveInteractiveAnswer('tc-2', { approve: false }), { ok: true });
    const d = getTerminalChoiceDecision('tc-2') as any;
    assert.equal(d.answered, true);
    assert.equal(d.decision.allow, false);
  } finally {
    server.close();
  }
});

test('resolveInteractiveAnswer returns not_found for an unknown requestId', () => {
  assert.deepEqual(resolveInteractiveAnswer('nope', { approve: true }), { ok: false, code: 'not_found' });
});
