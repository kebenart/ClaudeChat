import test from 'node:test';
import assert from 'node:assert/strict';

import { InMemoryImStore, MAX_MESSAGES_PER_CONVERSATION } from '@/services/im/store.js';

test('InMemoryImStore upserts conversations and messages, reads them back', async () => {
  const store = new InMemoryImStore();
  await store.upsertConversations([
    { id: 'c1', contactId: '/r', providerId: 'claude', title: 'C1', lastMessagePreview: 'hi', lastSeq: 2, lastActivityAt: 20, isPinned: false, isMuted: false },
  ]);
  await store.upsertMessages([
    { id: 's1', conversationId: 'c1', seq: 1, role: 'user', kind: 'text', content: 'hi', createdAt: 10 },
    { id: 's2', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: 'yo', createdAt: 20 },
  ]);

  assert.equal((await store.getConversations()).length, 1);
  const msgs = await store.getMessages('c1');
  assert.deepEqual(msgs.map((m) => m.seq), [1, 2]);
});

test('InMemoryImStore upsertMessages replaces by id (streaming update) and keeps seq order', async () => {
  const store = new InMemoryImStore();
  await store.upsertMessages([{ id: 'a1', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: 'part', createdAt: 1 }]);
  await store.upsertMessages([{ id: 'a1', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: 'part full', createdAt: 2 }]);
  const msgs = await store.getMessages('c1');
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].content, 'part full');
});

test('InMemoryImStore caps a conversation to the newest N messages by seq, ascending', async () => {
  const store = new InMemoryImStore();
  const total = MAX_MESSAGES_PER_CONVERSATION + 50; // 350 > cap of 300
  // Insert out of order (and in two batches) to prove eviction is by seq, not
  // insertion order, and survives the per-batch cap.
  const seqs = Array.from({ length: total }, (_, i) => i + 1);
  for (let i = seqs.length - 1; i >= 0; i--) {
    const seq = seqs[i];
    await store.upsertMessages([
      { id: `m${seq}`, conversationId: 'c1', seq, role: 'assistant', kind: 'result', content: String(seq), createdAt: seq },
    ]);
  }

  const msgs = await store.getMessages('c1');
  assert.equal(msgs.length, MAX_MESSAGES_PER_CONVERSATION);
  // Kept the newest 300 (seq 51..350) and dropped the oldest 50 (seq 1..50).
  assert.equal(msgs[0].seq, total - MAX_MESSAGES_PER_CONVERSATION + 1); // 51
  assert.equal(msgs[msgs.length - 1].seq, total); // 350
  // Returned ascending by seq.
  for (let i = 1; i < msgs.length; i++) assert.ok(msgs[i].seq > msgs[i - 1].seq);
});

test('InMemoryImStore cursor and read cursors round-trip', async () => {
  const store = new InMemoryImStore();
  await store.setCursor(7);
  assert.equal(await store.getCursor(), 7);
  await store.setReadCursor('c1', 'devA', 3);
  await store.setReadCursor('c1', 'devB', 5);
  const cursors = await store.getReadCursorsFor('c1');
  assert.deepEqual(cursors.sort((a, b) => a.lastReadSeq - b.lastReadSeq).map((c) => c.lastReadSeq), [3, 5]);
});
