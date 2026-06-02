import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';
import {
  recordUserMessage,
  recordAssistantMessage,
  recordImageMessage,
  recordChoiceCard,
  resolveChoiceCard,
  beginSdkTurn,
  endSdkTurn,
  isSdkTurnActive,
  __resetSdkTurns,
} from '@/services/im-record.service.js';
import { serializeMessage, IM_CONTENT_PREVIEW_LIMIT } from '@/services/im-events.service.js';
import {
  ingestSessionJsonl,
  __resetImIngestCheckpoints,
} from '@/services/im-ingest.service.js';

function freshDb() {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  __setConnectionForTests(db);
  return db;
}

afterEach(() => {
  __setConnectionForTests(null);
  __resetSdkTurns();
  __resetImIngestCheckpoints();
});

function writeJsonl(lines: object[]): string {
  const dir = mkdtempSync(join(tmpdir(), 'im-record-'));
  const file = join(dir, 'sess.jsonl');
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join('\n'), 'utf8');
  return file;
}

test('recordUserMessage creates the conversation and an authoritative user bubble', () => {
  freshDb();
  const n = recordUserMessage({
    sessionId: 'sess-u',
    contactId: '/repo',
    title: 'hello',
    content: 'do the thing',
    clientMsgId: 'cmid-1',
  });
  assert.equal(n, 1);

  const msgs = imDb.listMessages('sess-u', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].role, 'user');
  assert.equal(msgs[0].kind, 'text');
  assert.equal(msgs[0].content, 'do the thing');
  assert.equal(msgs[0].source_id, 'cmid-1');

  // The conversation was upserted with the contact (project path).
  const conv = imDb.listConversations().find((c) => c.id === 'sess-u');
  assert.ok(conv);
  assert.equal(conv!.contact_id, '/repo');
});

test('recordUserMessage is idempotent on clientMsgId (a resend records one row)', () => {
  freshDb();
  const opts = { sessionId: 'sess-i', contactId: '/r', title: null, content: 'q', clientMsgId: 'dup' };
  assert.equal(recordUserMessage(opts), 1);
  assert.equal(recordUserMessage(opts), 0); // same sourceId -> no new row
  assert.equal(imDb.listMessages('sess-i', { numBefore: 100, numAfter: 0 }).length, 1);
});

test('dedupeWindowMs skips a user message the SDK already recorded under a different sourceId', () => {
  freshDb();
  // SDK path recorded the bubble keyed by clientMsgId.
  assert.equal(
    recordUserMessage({ sessionId: 's-dup', contactId: '/r', title: null, content: 'hi there', clientMsgId: 'cmid' }),
    1,
  );
  // Hook path fires for the same prompt (no clientMsgId → different sourceId).
  // With the dedup window set, it must collapse to the existing row.
  assert.equal(
    recordUserMessage({ sessionId: 's-dup', contactId: '/r', title: null, content: 'hi there', clientMsgId: null, dedupeWindowMs: 15_000 }),
    0,
  );
  assert.equal(imDb.listMessages('s-dup', { numBefore: 100, numAfter: 0 }).length, 1);
});

test('dedupeWindowMs still records when no recent identical user message exists', () => {
  freshDb();
  // No prior bubble → the hook records normally even with the window set.
  // Distinct createdAt so the derived sourceIds (user-send:sid:<ms>) differ —
  // two real terminal prompts never land in the same millisecond.
  assert.equal(
    recordUserMessage({ sessionId: 's-new', contactId: '/r', title: null, content: 'fresh prompt', clientMsgId: null, dedupeWindowMs: 15_000, createdAt: 1000 }),
    1,
  );
  // A DIFFERENT prompt is never collapsed by the window.
  assert.equal(
    recordUserMessage({ sessionId: 's-new', contactId: '/r', title: null, content: 'another prompt', clientMsgId: null, dedupeWindowMs: 15_000, createdAt: 2000 }),
    1,
  );
  assert.equal(imDb.listMessages('s-new', { numBefore: 100, numAfter: 0 }).length, 2);
});

test('the SDK path (no dedupeWindowMs) never collapses legitimately-repeated prompts', () => {
  freshDb();
  // Two identical prompts with distinct clientMsgIds — both kept (e.g. "ok"/"ok").
  assert.equal(recordUserMessage({ sessionId: 's-rep', contactId: '/r', title: null, content: 'ok', clientMsgId: 'c1' }), 1);
  assert.equal(recordUserMessage({ sessionId: 's-rep', contactId: '/r', title: null, content: 'ok', clientMsgId: 'c2' }), 1);
  assert.equal(imDb.listMessages('s-rep', { numBefore: 100, numAfter: 0 }).length, 2);
});

test('recordAssistantMessage records exactly one assistant bubble at completion', () => {
  freshDb();
  recordUserMessage({ sessionId: 'sess-a', contactId: '/r', title: 'q', content: 'q', clientMsgId: 'u' });
  const n = recordAssistantMessage({
    sessionId: 'sess-a',
    contactId: '/r',
    title: 'q',
    content: 'the final answer',
    sourceId: 'a1', // turn's first assistant uuid
    createdAt: 1000,
  });
  assert.equal(n, 1);

  const msgs = imDb.listMessages('sess-a', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 2);
  assert.deepEqual(msgs.map((m) => m.role), ['user', 'assistant']);
  assert.equal(msgs[1].kind, 'result');
  assert.equal(msgs[1].content, 'the final answer');
  assert.equal(msgs[1].source_id, 'a1');
});

test('recordImageMessage records a kind:image bubble keyed on the media id', () => {
  freshDb();
  const n = recordImageMessage({
    sessionId: 's-img',
    contactId: '/r',
    title: null,
    mediaId: 'deadbeef00112233445566778899aabb.png',
    caption: '测试结果',
  });
  assert.equal(n, 1);
  const msgs = imDb.listMessages('s-img', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].kind, 'image');
  assert.equal(msgs[0].source_id, 'image:deadbeef00112233445566778899aabb.png');
  const payload = JSON.parse(msgs[0].content);
  assert.equal(payload.mediaId, 'deadbeef00112233445566778899aabb.png');
  assert.equal(payload.caption, '测试结果');
  // The same image (same media id + same caption) re-sent collapses to one row.
  assert.equal(
    recordImageMessage({ sessionId: 's-img', contactId: '/r', title: null, mediaId: 'deadbeef00112233445566778899aabb.png', caption: '测试结果' }),
    0,
  );
  assert.equal(imDb.listMessages('s-img', { numBefore: 100, numAfter: 0 }).length, 1);
});

test('serializeMessage never truncates a kind:image payload', () => {
  freshDb();
  // A pathologically long (but valid) image payload must NOT be truncated.
  const longCaption = 'x'.repeat(IM_CONTENT_PREVIEW_LIMIT + 500);
  recordImageMessage({ sessionId: 's-img2', contactId: null, title: null, mediaId: 'aabbccddeeff00112233445566778899.jpg', caption: longCaption });
  const row = imDb.listMessages('s-img2', { numBefore: 100, numAfter: 0 })[0];
  const ser = serializeMessage(row);
  assert.equal(ser.truncated, undefined);
  assert.equal(ser.content, row.content); // full JSON, parseable
  assert.equal(JSON.parse(ser.content).mediaId, 'aabbccddeeff00112233445566778899.jpg');
});

test('an empty non-error assistant turn records nothing', () => {
  freshDb();
  const n = recordAssistantMessage({ sessionId: 's', contactId: null, title: null, content: '   ', sourceId: 'a1' });
  assert.equal(n, 0);
});

test('an error completion records an error-kind assistant bubble', () => {
  freshDb();
  const n = recordAssistantMessage({ sessionId: 's', contactId: null, title: null, content: 'boom', sourceId: 'a1', isError: true });
  assert.equal(n, 1);
  const msgs = imDb.listMessages('s', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs[0].kind, 'error');
});

test('a later watcher pass with the SAME assistant sourceId does NOT duplicate or re-broadcast', async () => {
  freshDb();
  // SDK path: record user (clientMsgId) + assistant (first-assistant uuid = 'a1').
  recordUserMessage({ sessionId: 'sess-d', contactId: '/r', title: 'q', content: 'q', clientMsgId: 'u-cmid' });
  recordAssistantMessage({
    sessionId: 'sess-d',
    contactId: '/r',
    title: 'q',
    content: 'final',
    sourceId: 'a1',
    createdAt: 2000,
  });
  const before = imDb.listMessages('sess-d', { numBefore: 100, numAfter: 0 });
  assert.equal(before.length, 2);

  // The watcher later distills the SAME jsonl turn. distillJsonl keys the
  // assistant bubble on the turn's first assistant uuid ('a1') — identical to
  // the SDK-path sourceId — so re-ingesting that assistant row is a no-op.
  const file = writeJsonl([
    { type: 'user', uuid: 'u-jsonl', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'final' }] } },
  ]);
  const inserted = await ingestSessionJsonl({ sessionId: 'sess-d', contactId: '/r', title: 'q', jsonlPath: file });

  // Only the user row (distill keyed on the jsonl uuid 'u-jsonl', which differs
  // from our clientMsgId) is newly inserted; the assistant 'a1' dedups.
  assert.equal(inserted, 1);
  const after = imDb.listMessages('sess-d', { numBefore: 100, numAfter: 0 });
  const assistants = after.filter((m) => m.role === 'assistant');
  assert.equal(assistants.length, 1, 'assistant bubble must not be duplicated');
  assert.equal(assistants[0].source_id, 'a1');
});

test('recordChoiceCard writes a pending kind:choice message keyed on the requestId', () => {
  freshDb();
  const n = recordChoiceCard({
    sessionId: 'sess-c',
    contactId: '/r',
    title: 'q',
    requestId: 'req-1',
    toolName: 'AskUserQuestion',
    questions: [{ question: 'Pick a color', header: 'Color', multiSelect: false, options: [{ label: 'Red' }, { label: 'Blue' }] }],
  });
  assert.equal(n, 1);

  const msgs = imDb.listMessages('sess-c', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].kind, 'choice');
  assert.equal(msgs[0].role, 'assistant');
  assert.equal(msgs[0].source_id, 'choice:req-1');

  const card = JSON.parse(msgs[0].content);
  assert.equal(card.requestId, 'req-1');
  assert.equal(card.toolName, 'AskUserQuestion');
  assert.equal(card.questions[0].question, 'Pick a color');
  assert.equal(card.answered, undefined);
});

test('recordChoiceCard for ExitPlanMode stores the plan text', () => {
  freshDb();
  recordChoiceCard({
    sessionId: 'sess-p',
    contactId: '/r',
    title: null,
    requestId: 'req-p',
    toolName: 'ExitPlanMode',
    plan: 'Step 1. Do thing\nStep 2. Done',
  });
  const msgs = imDb.listMessages('sess-p', { numBefore: 100, numAfter: 0 });
  const card = JSON.parse(msgs[0].content);
  assert.equal(card.toolName, 'ExitPlanMode');
  assert.equal(card.plan, 'Step 1. Do thing\nStep 2. Done');
  assert.equal(card.questions, undefined);
});

test('resolveChoiceCard UPSERTs the same row to a terminal answered state', () => {
  freshDb();
  recordChoiceCard({
    sessionId: 'sess-r',
    contactId: '/r',
    title: 'q',
    requestId: 'req-2',
    toolName: 'AskUserQuestion',
    questions: [{ question: 'Pick a color', options: [{ label: 'Red' }, { label: 'Blue' }] }],
  });
  const n = resolveChoiceCard({
    sessionId: 'sess-r',
    contactId: '/r',
    title: 'q',
    requestId: 'req-2',
    toolName: 'AskUserQuestion',
    questions: [{ question: 'Pick a color', options: [{ label: 'Red' }, { label: 'Blue' }] }],
    answer: '已选择 Red',
  });
  assert.equal(n, 1); // content changed → one affected (updated) row

  const msgs = imDb.listMessages('sess-r', { numBefore: 100, numAfter: 0 });
  // Same sourceId → still exactly one message (UPSERT in place).
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].source_id, 'choice:req-2');
  const card = JSON.parse(msgs[0].content);
  assert.equal(card.answered, true);
  assert.equal(card.answer, '已选择 Red');
});

test('serializeMessage never truncates a kind:choice payload', () => {
  freshDb();
  // Build a choice card whose JSON content exceeds the preview limit.
  const bigQuestions = Array.from({ length: 50 }, (_, i) => ({
    question: `Question number ${i} with some padding text to make it long`,
    options: [{ label: `Option A ${i}` }, { label: `Option B ${i}` }],
  }));
  recordChoiceCard({
    sessionId: 'sess-big',
    contactId: '/r',
    title: null,
    requestId: 'req-big',
    toolName: 'AskUserQuestion',
    questions: bigQuestions,
  });
  const row = imDb.listMessages('sess-big', { numBefore: 100, numAfter: 0 })[0];
  assert.ok(row.content.length > IM_CONTENT_PREVIEW_LIMIT, 'precondition: content exceeds preview limit');

  const ser = serializeMessage(row);
  assert.equal(ser.truncated, undefined, 'choice cards must not be marked truncated');
  assert.equal(ser.content.length, row.content.length, 'full JSON must survive');
  // And it must still parse.
  const card = JSON.parse(ser.content);
  assert.equal(card.requestId, 'req-big');
});

test('the active-turn gate suppresses the watcher during a live turn, with a post-turn grace window', () => {
  freshDb();
  assert.equal(isSdkTurnActive('sess-g'), false);

  beginSdkTurn('sess-g');
  assert.equal(isSdkTurnActive('sess-g'), true); // in-flight: watcher suppressed

  const t0 = 10_000;
  endSdkTurn('sess-g', t0);
  // Still suppressed within the grace window (covers the watcher's trailing
  // debounced jsonl pass that would otherwise insert a duplicate user bubble).
  assert.equal(isSdkTurnActive('sess-g', t0 + 1_000), true);
  // After the grace window the watcher resumes (history backfill works).
  assert.equal(isSdkTurnActive('sess-g', t0 + 60_000), false);
});
