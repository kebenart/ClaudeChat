import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';

import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { INIT_SCHEMA_SQL } from '@/modules/database/schema.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';

function freshDb() {
  const db = new Database(':memory:');
  db.exec(INIT_SCHEMA_SQL);
  runMigrations(db);
  __setConnectionForTests(db);
  return db;
}

afterEach(() => {
  __setConnectionForTests(null);
});

test('insertMessages assigns monotonic per-conversation seq and is idempotent', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');

  const first = imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
    { sourceId: 's2', role: 'assistant', kind: 'result', content: 'hello', createdAt: 2 },
  ]);
  assert.equal(first.length, 2);
  assert.equal(imDb.getMaxSeq('c1'), 2);

  // Re-upsert s1 with IDENTICAL content (no-op) + a new s3 → only s3 is affected.
  const second = imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
    { sourceId: 's3', role: 'assistant', kind: 'result', content: 'again', createdAt: 3 },
  ]);
  assert.equal(second.length, 1);
  assert.equal(second[0].source_id, 's3');
  assert.equal(imDb.getMaxSeq('c1'), 3);

  const msgs = imDb.listMessages('c1', { numBefore: 100, numAfter: 0 });
  assert.deepEqual(msgs.map((m) => m.seq), [1, 2, 3]);
  assert.deepEqual(msgs.map((m) => m.source_id), ['s1', 's2', 's3']);
});

test('insertMessages upserts a growing message in place without changing its seq', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [{ sourceId: 'u1', role: 'user', kind: 'text', content: 'q', createdAt: 1 }]);

  // First partial of a streaming assistant turn.
  const a = imDb.insertMessages('c1', [{ sourceId: 'a1', role: 'assistant', kind: 'result', content: 'Part one.', createdAt: 2 }]);
  assert.equal(a.length, 1);
  assert.equal(a[0].seq, 2);

  // Same source_id, grown content → UPDATE in place, same seq, affected once.
  const b = imDb.insertMessages('c1', [{ sourceId: 'a1', role: 'assistant', kind: 'result', content: 'Part one. Part two.', createdAt: 3 }]);
  assert.equal(b.length, 1);
  assert.equal(b[0].seq, 2);
  assert.equal(b[0].content, 'Part one. Part two.');

  // No duplicate row was created.
  const msgs = imDb.listMessages('c1', { numBefore: 100, numAfter: 0 });
  assert.equal(msgs.length, 2);
  assert.equal(imDb.getMaxSeq('c1'), 2);
});

test('read cursor upsert and changedSince cursor work', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [{ sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 }]);

  imDb.setReadCursor('c1', 'deviceA', 1);
  const cursors = imDb.getReadCursors();
  assert.equal(cursors.find((c) => c.device_id === 'deviceA')?.last_read_seq, 1);

  const since0 = imDb.getMessagesSince(0, 100);
  assert.equal(since0.rows.length, 1);
  assert.ok(since0.cursor >= 1);
  const sinceTop = imDb.getMessagesSince(since0.cursor, 100);
  assert.equal(sinceTop.rows.length, 0);
});

test('pruneConversationsOlderThan removes stale conversations + their messages, keeps active ones', () => {
  freshDb();
  imDb.ensureConversation('old', 'projA', 'Old');
  imDb.insertMessages('old', [{ sourceId: 'o1', role: 'user', kind: 'text', content: 'old', createdAt: 1_000 }]); // last_activity_at=1000
  imDb.ensureConversation('fresh', 'projB', 'Fresh');
  imDb.insertMessages('fresh', [{ sourceId: 'f1', role: 'user', kind: 'text', content: 'new', createdAt: 9_000 }]); // last_activity_at=9000

  const removed = imDb.pruneConversationsOlderThan(5_000);
  assert.equal(removed, 1);
  const ids = imDb.listConversations().map((c) => c.id);
  assert.deepEqual(ids, ['fresh']);
  assert.equal(imDb.listMessages('old', { numBefore: 100, numAfter: 0 }).length, 0);
  assert.equal(imDb.listMessages('fresh', { numBefore: 100, numAfter: 0 }).length, 1);
});

test('deleteConversationsByContact closes all of a contact’s conversations', () => {
  freshDb();
  imDb.ensureConversation('c1', 'projX', 'X1');
  imDb.insertMessages('c1', [{ sourceId: 'm1', role: 'user', kind: 'text', content: 'a', createdAt: 1 }]);
  imDb.ensureConversation('c2', 'projX', 'X2');
  imDb.insertMessages('c2', [{ sourceId: 'm2', role: 'user', kind: 'text', content: 'b', createdAt: 2 }]);
  imDb.ensureConversation('c3', 'projY', 'Y1');
  imDb.setReadCursor('c1', 'dev', 1);

  const removed = imDb.deleteConversationsByContact('projX');
  assert.equal(removed, 2);
  assert.deepEqual(imDb.listConversations().map((c) => c.id), ['c3']);
  assert.equal(imDb.listMessages('c1', { numBefore: 100, numAfter: 0 }).length, 0);
  assert.equal(imDb.getReadCursors().filter((r) => r.conversation_id === 'c1').length, 0);
});

test('getMessagesSince re-delivers an in-place content update past the cursor', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [{ sourceId: 'a1', role: 'assistant', kind: 'result', content: 'partial', createdAt: 1 }]);

  const first = imDb.getMessagesSince(0, 100);
  assert.equal(first.rows.length, 1);
  const afterFirst = imDb.getMessagesSince(first.cursor, 100);
  assert.equal(afterFirst.rows.length, 0); // caught up

  // Same source_id grows → UPDATE in place bumps rev → re-delivered past the cursor.
  imDb.insertMessages('c1', [{ sourceId: 'a1', role: 'assistant', kind: 'result', content: 'partial then full', createdAt: 2 }]);
  const afterUpdate = imDb.getMessagesSince(first.cursor, 100);
  assert.equal(afterUpdate.rows.length, 1);
  assert.equal(afterUpdate.rows[0].source_id, 'a1');
  assert.equal(afterUpdate.rows[0].content, 'partial then full');
});

test('conversation preview/activity track the newest message even when an older one updates', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [
    { sourceId: 'u1', role: 'user', kind: 'text', content: 'first', createdAt: 10 },
    { sourceId: 'a1', role: 'assistant', kind: 'result', content: 'newest answer', createdAt: 20 },
  ]);

  // Re-ingest with the OLDER message (u1) edited; the newest row (a1) is unchanged.
  imDb.insertMessages('c1', [
    { sourceId: 'u1', role: 'user', kind: 'text', content: 'first (edited)', createdAt: 10 },
    { sourceId: 'a1', role: 'assistant', kind: 'result', content: 'newest answer', createdAt: 20 },
  ]);

  const conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.last_seq, 2);
  assert.equal(conv?.last_message_preview, 'newest answer'); // not the edited older message
  assert.equal(conv?.last_activity_at, 20); // did not roll back to 10
});

test('listConversations and setConversationState reflect pin/mute', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [{ sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 }]);
  imDb.setConversationState('c1', { isPinned: true, isMuted: true });
  const conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.is_pinned, 1);
  assert.equal(conv?.is_muted, 1);
  assert.equal(conv?.last_seq, 1);
});

test('listMessages: centered window around anchor, and latest-page when no anchor', () => {
  freshDb();
  imDb.ensureConversation('c1', 'p', 't');
  imDb.insertMessages(
    'c1',
    Array.from({ length: 10 }, (_, i) => ({
      sourceId: `s${i + 1}`, role: 'user' as const, kind: 'text' as const, content: `m${i + 1}`, createdAt: i + 1,
    }))
  );
  const win = imDb.listMessages('c1', { anchorSeq: 6, numBefore: 2, numAfter: 3 });
  assert.deepEqual(win.map((m) => m.seq), [4, 5, 6, 7, 8]);

  const latest = imDb.listMessages('c1', { numBefore: 3, numAfter: 0 });
  assert.deepEqual(latest.map((m) => m.seq), [8, 9, 10]);
});

test('soft delete hides a conversation and a new message resurrects it', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');
  imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
  ]);

  // Delete → is_deleted flag set, conversation still present (soft).
  imDb.setConversationState('c1', { isDeleted: true });
  let conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.is_deleted, 1);

  // A content-only edit of an existing message does NOT resurrect it.
  imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
  ]);
  conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.is_deleted, 1);

  // A genuinely new inbound message clears the flag (WeChat-style resurrect).
  imDb.insertMessages('c1', [
    { sourceId: 's2', role: 'assistant', kind: 'result', content: 'reply', createdAt: 2 },
  ]);
  conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.is_deleted, 0);

  // Explicit un-delete also works.
  imDb.setConversationState('c1', { isDeleted: true });
  imDb.setConversationState('c1', { isDeleted: false });
  conv = imDb.listConversations().find((c) => c.id === 'c1');
  assert.equal(conv?.is_deleted, 0);
});
