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
  ingestSessionJsonl,
  ingestAndBroadcast,
  __resetImIngestCheckpoints,
  __imIngestCheckpoint,
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
  __resetImIngestCheckpoints();
});

function writeJsonl(lines: object[]): string {
  const dir = mkdtempSync(join(tmpdir(), 'im-ingest-'));
  const file = join(dir, 'sess.jsonl');
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join('\n'), 'utf8');
  return file;
}

function writeLines(file: string, lines: object[]): void {
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join('\n'), 'utf8');
}

function mkUser(uuid: string, content: string): object {
  return { type: 'user', uuid, timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content } };
}
function mkAsst(uuid: string, text: string): object {
  return { type: 'assistant', uuid, timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text }] } };
}

test('ingestSessionJsonl distills a jsonl file into imDb messages', async () => {
  freshDb();
  const file = writeJsonl([
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', cwd: '/repo', message: { role: 'user', content: 'hello' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'hi there' }] } },
  ]);

  const inserted = await ingestSessionJsonl({ sessionId: 'sess1', contactId: '/repo', title: 'hello', jsonlPath: file });
  assert.equal(inserted, 2);

  const msgs = imDb.listMessages('sess1', { numBefore: 100, numAfter: 0 });
  assert.deepEqual(msgs.map((m) => m.content), ['hello', 'hi there']);

  const again = await ingestSessionJsonl({ sessionId: 'sess1', contactId: '/repo', title: 'hello', jsonlPath: file });
  assert.equal(again, 0);
});

test('ingestSessionJsonl skips malformed lines and tolerates a missing file gracefully', async () => {
  freshDb();
  const dir = mkdtempSync(join(tmpdir(), 'im-ingest-'));
  const file = join(dir, 'sess.jsonl');
  writeFileSync(
    file,
    [
      JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } }),
      'not-json-garbage',
      '',
      JSON.stringify({ type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'a' }] } }),
    ].join('\n'),
    'utf8'
  );

  const inserted = await ingestSessionJsonl({ sessionId: 'sess2', contactId: null, title: null, jsonlPath: file });
  assert.equal(inserted, 2);
});

test('ingestAndBroadcast emits one frame per newly inserted message, nothing on re-ingest', async () => {
  freshDb();
  const file = writeJsonl([
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'a' }] } },
  ]);

  const frames: any[] = [];
  const inserted = await ingestAndBroadcast(
    { sessionId: 'sess3', contactId: '/r', title: 'q', jsonlPath: file },
    (frame) => frames.push(frame)
  );
  assert.equal(inserted, 2);
  assert.equal(frames.length, 2);
  assert.equal(frames[1].type, 'im:message');
  assert.equal(frames[1].message.content, 'a');

  // Re-ingest: nothing new, no frames emitted.
  const frames2: any[] = [];
  const again = await ingestAndBroadcast(
    { sessionId: 'sess3', contactId: '/r', title: 'q', jsonlPath: file },
    (frame) => frames2.push(frame)
  );
  assert.equal(again, 0);
  assert.equal(frames2.length, 0);
});

test('a streaming turn re-ingested as it grows updates one bubble (no duplicate, no orphan)', async () => {
  freshDb();
  const u1 = { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } };
  const a1partial = { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'Part one.' }] } };
  const a2 = { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'assistant', content: [{ type: 'text', text: ' Part two.' }] } };

  const file = writeJsonl([u1, a1partial]);
  const opts = { sessionId: 'streamy', contactId: '/r', title: 'q', jsonlPath: file };

  const frames1: any[] = [];
  await ingestAndBroadcast(opts, (f) => frames1.push(f));
  assert.equal(frames1.length, 2); // user + partial result

  // The watcher fires again after the turn grew; re-ingest the whole file.
  writeLines(file, [u1, a1partial, a2]);
  const frames2: any[] = [];
  await ingestAndBroadcast(opts, (f) => frames2.push(f));
  assert.equal(frames2.length, 1); // only the (updated) result re-broadcast
  assert.equal(frames2[0].message.content, 'Part one. Part two.');

  // Exactly two rows — the partial bubble was UPDATED in place, not duplicated.
  const msgs = imDb.listMessages('streamy', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 2);
  assert.deepEqual(msgs.map((m) => m.content), ['q', 'Part one. Part two.']);
});

test('incremental ingest re-distills only from the last turn boundary, advancing the checkpoint', async () => {
  freshDb();
  const file = writeJsonl([mkUser('u1', 'q1'), mkAsst('a1', 'a1'), mkUser('u2', 'q2'), mkAsst('a2', 'a2')]);
  const opts = { sessionId: 'inc', contactId: '/r', title: 'q', jsonlPath: file };

  await ingestSessionJsonl(opts);
  // The checkpoint moved past the first finalized turn to the second user msg.
  const cp1 = __imIngestCheckpoint('inc');
  assert.ok(cp1 !== undefined && cp1 > 0, `expected checkpoint > 0, got ${cp1}`);

  // A new turn is appended; the re-ingest must pick it up despite NOT re-reading
  // the earlier turns (the rewind starts at the last boundary).
  writeLines(file, [mkUser('u1', 'q1'), mkAsst('a1', 'a1'), mkUser('u2', 'q2'), mkAsst('a2', 'a2'), mkUser('u3', 'q3'), mkAsst('a3', 'a3')]);
  const frames: any[] = [];
  await ingestAndBroadcast(opts, (f) => frames.push(f));
  assert.deepEqual(frames.map((f) => f.message.content), ['q3', 'a3']); // only the new turn

  const cp2 = __imIngestCheckpoint('inc')!;
  assert.ok(cp2 > cp1!, `expected checkpoint to advance: ${cp1} -> ${cp2}`);

  // The full conversation is intact with correct monotonic seqs.
  const msgs = imDb.listMessages('inc', { numBefore: 100, numAfter: 0 });
  assert.deepEqual(msgs.map((m) => m.content), ['q1', 'a1', 'q2', 'a2', 'q3', 'a3']);
  assert.deepEqual(msgs.map((m) => m.seq), [1, 2, 3, 4, 5, 6]);
});

test('a trailing tool_result appended after the boundary keeps the turn as one row', async () => {
  freshDb();
  const u1 = mkUser('u1', 'q');
  // assistant turn: tool_use then a concluding text — the text grows on the
  // second event so insertMessages actually rewrites the row.
  const a1 = { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Read' }] } };
  const tr = { type: 'user', uuid: 't1', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'user', content: [{ type: 'tool_result' }] } };
  const a2 = { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:03.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } };
  const file = writeJsonl([u1, a1]);
  const opts = { sessionId: 'tool', contactId: '/r', title: 'q', jsonlPath: file };

  await ingestSessionJsonl(opts);
  // The tool_result + concluding text arrive in a later watcher event. A
  // tool_result is NOT a turn boundary, so the checkpoint stays anchored at u1
  // and the whole turn is re-distilled — UPDATING the one assistant row, never
  // appending a duplicate/orphan.
  writeLines(file, [u1, a1, tr, a2]);
  await ingestSessionJsonl(opts);

  const msgs = imDb.listMessages('tool', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 2); // user + the assistant turn (still ONE row)
  assert.equal(msgs[1].content, 'done');
  assert.equal(msgs[1].raw_ref_end, 't1'); // rawRef range extended to the tool_result
});

test('a truncated/rotated jsonl re-reads from the top', async () => {
  freshDb();
  const file = writeJsonl([mkUser('u1', 'q1'), mkAsst('a1', 'a1'), mkUser('u2', 'q2'), mkAsst('a2', 'a2')]);
  const opts = { sessionId: 'rot', contactId: '/r', title: 'q', jsonlPath: file };
  await ingestSessionJsonl(opts);

  // Replace with a SHORTER file (rotation/replacement) — the stale offset would
  // skip everything, so ingest must detect the shrink and re-read from 0.
  writeLines(file, [mkUser('n1', 'newq'), mkAsst('n2', 'newa')]);
  const frames: any[] = [];
  await ingestAndBroadcast(opts, (f) => frames.push(f));
  assert.deepEqual(frames.map((f) => f.message.content), ['newq', 'newa']);
});
