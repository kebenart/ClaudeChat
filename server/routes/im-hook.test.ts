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
import imHookRoutes from '@/routes/im-hook.js';
import { beginSdkTurn, __resetSdkTurns } from '@/services/im-record.service.js';

async function startServer() {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  __setConnectionForTests(db);
  __resetSdkTurns();
  const app = express();
  app.use(express.json());
  app.use('/api/im-hook', imHookRoutes);
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const port = (server.address() as { port: number }).port;
  return { server, base: `http://127.0.0.1:${port}/api/im-hook` };
}

function allMessages(conversationId: string) {
  const { rows } = imDb.getMessagesSince(0, 1000);
  return rows.filter((r) => r.conversation_id === conversationId);
}

afterEach(() => {
  __setConnectionForTests(null);
  __resetSdkTurns();
  delete process.env.IM_HOOK_TOKEN;
});

test('user event records a user message when no SDK turn is active', async () => {
  const { server, base } = await startServer();
  try {
    const res = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event: 'user',
        sessionId: 'term-1',
        projectPath: '/repo',
        content: 'hello from terminal',
      }),
    });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });

    const msgs = allMessages('term-1');
    assert.equal(msgs.length, 1);
    assert.equal(msgs[0].role, 'user');
    assert.equal(msgs[0].kind, 'text');
    assert.equal(msgs[0].content, 'hello from terminal');
  } finally {
    server.close();
  }
});

test('user event SKIPS when an SDK turn is active for the session', async () => {
  const { server, base } = await startServer();
  try {
    beginSdkTurn('term-2'); // simulate an in-flight SDK (app) turn

    const res = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event: 'user',
        sessionId: 'term-2',
        projectPath: '/repo',
        content: 'should be skipped',
      }),
    });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });

    assert.equal(allMessages('term-2').length, 0);
  } finally {
    server.close();
  }
});

test('stop event records the last assistant turn from the transcript', async () => {
  const { server, base } = await startServer();
  const dir = mkdtempSync(join(tmpdir(), 'im-hook-'));
  const transcriptPath = join(dir, 'transcript.jsonl');
  const lines = [
    { type: 'user', uuid: 'u1', timestamp: '2026-05-31T00:00:00.000Z', message: { content: 'q1' } },
    {
      type: 'assistant',
      uuid: 'a1',
      timestamp: '2026-05-31T00:00:01.000Z',
      message: { content: [{ type: 'text', text: 'final answer' }] },
    },
  ];
  writeFileSync(transcriptPath, lines.map((l) => JSON.stringify(l)).join('\n'));
  try {
    const res = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event: 'stop',
        sessionId: 'term-3',
        projectPath: '/repo',
        transcriptPath,
      }),
    });
    assert.equal(res.status, 200);

    const msgs = allMessages('term-3');
    const assistant = msgs.filter((m) => m.role === 'assistant');
    assert.equal(assistant.length, 1);
    assert.equal(assistant[0].kind, 'result');
    assert.equal(assistant[0].content, 'final answer');
    // sourceId == the turn's first assistant uuid → dedups vs watcher/SDK passes.
    assert.equal(assistant[0].source_id, 'a1');
  } finally {
    server.close();
  }
});

test('non-loopback request is rejected', async () => {
  // The gate reads `req.socket.remoteAddress`. Mount a middleware that rewrites
  // it to a public IP before the router so the request looks like a remote peer.
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  __setConnectionForTests(db);
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    Object.defineProperty(req.socket, 'remoteAddress', {
      value: '203.0.113.7',
      configurable: true,
    });
    next();
  });
  app.use('/api/im-hook', imHookRoutes);
  const server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  const port = (server.address() as { port: number }).port;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/im-hook/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ event: 'user', sessionId: 's', projectPath: '/r', content: 'x' }),
    });
    assert.equal(res.status, 403);
  } finally {
    server.close();
  }
});

test('IM_HOOK_TOKEN gate: wrong/missing token → 403, correct token → 200', async () => {
  process.env.IM_HOOK_TOKEN = 'secret-token';
  const { server, base } = await startServer();
  try {
    // Missing token.
    const missing = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ event: 'user', sessionId: 't', projectPath: '/r', content: 'x' }),
    });
    assert.equal(missing.status, 403);

    // Wrong token.
    const wrong = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-IM-Hook-Token': 'nope' },
      body: JSON.stringify({ event: 'user', sessionId: 't', projectPath: '/r', content: 'x' }),
    });
    assert.equal(wrong.status, 403);

    // Correct token.
    const ok = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-IM-Hook-Token': 'secret-token' },
      body: JSON.stringify({ event: 'user', sessionId: 't', projectPath: '/r', content: 'ok now' }),
    });
    assert.equal(ok.status, 200);
    assert.equal(allMessages('t').length, 1);
  } finally {
    server.close();
  }
});
