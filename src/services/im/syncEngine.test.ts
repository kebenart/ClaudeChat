import test from 'node:test';
import assert from 'node:assert/strict';

import { InMemoryImStore } from '@/services/im/store.js';
import { applySync, applyFrame, computeUnread } from '@/services/im/syncEngine.js';
import type { SyncResponse } from '@/services/im/protocol.js';

function syncResp(partial: Partial<SyncResponse>): SyncResponse {
  return { messages: [], conversations: [], readCursors: [], cursor: 0, hasMore: false, ...partial };
}

test('applySync stores conversations/messages/cursor/readCursors', async () => {
  const store = new InMemoryImStore();
  await applySync(store, syncResp({
    conversations: [{ id: 'c1', contactId: '/r', providerId: 'claude', title: 'C1', lastMessagePreview: 'yo', lastSeq: 2, lastActivityAt: 20, isPinned: false, isMuted: false }],
    messages: [
      { id: 's1', conversationId: 'c1', seq: 1, role: 'user', kind: 'text', content: 'hi', createdAt: 10 },
      { id: 's2', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: 'yo', createdAt: 20 },
    ],
    readCursors: [{ conversationId: 'c1', deviceId: 'devA', lastReadSeq: 1 }],
    cursor: 2,
  }));
  assert.equal(await store.getCursor(), 2);
  assert.equal((await store.getMessages('c1')).length, 2);
  assert.equal((await store.getReadCursorsFor('c1'))[0].lastReadSeq, 1);
});

test('computeUnread counts only Claude replies, ignoring my own + non-reply rows', async () => {
  const store = new InMemoryImStore();
  await applySync(store, syncResp({
    conversations: [{ id: 'c1', contactId: null, providerId: 'claude', title: 'C1', lastMessagePreview: '', lastSeq: 4, lastActivityAt: 1, isPinned: false, isMuted: false }],
    messages: [
      { id: 'u1', conversationId: 'c1', seq: 1, role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
      { id: 't1', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'tool_use', content: '', createdAt: 2 },
      { id: 'a1', conversationId: 'c1', seq: 3, role: 'assistant', kind: 'result', content: 'r1', createdAt: 3 },
      { id: 'a2', conversationId: 'c1', seq: 4, role: 'assistant', kind: 'result', content: 'r2', createdAt: 4 },
    ],
    readCursors: [{ conversationId: 'c1', deviceId: 'phone', lastReadSeq: 0 }],
    cursor: 4,
  }));
  // Two assistant result rows; the user's own text and the tool_use are excluded.
  assert.equal((await computeUnread(store))['c1'], 2);
});

test('computeUnread clears once the max read cursor across devices passes the replies', async () => {
  const store = new InMemoryImStore();
  await applySync(store, syncResp({
    conversations: [{ id: 'c1', contactId: null, providerId: 'claude', title: 'C1', lastMessagePreview: '', lastSeq: 5, lastActivityAt: 1, isPinned: false, isMuted: false }],
    messages: [
      { id: 'a1', conversationId: 'c1', seq: 3, role: 'assistant', kind: 'result', content: 'r', createdAt: 3 },
      { id: 'a2', conversationId: 'c1', seq: 5, role: 'assistant', kind: 'result', content: 'r', createdAt: 5 },
    ],
    readCursors: [
      { conversationId: 'c1', deviceId: 'phone', lastReadSeq: 5 },
      { conversationId: 'c1', deviceId: 'desktop', lastReadSeq: 2 },
    ],
    cursor: 5,
  }));
  // Reading on phone (max cursor = 5) clears both replies everywhere.
  assert.equal((await computeUnread(store))['c1'], 0);
});

test('applyFrame im:message upserts the message and bumps conversation lastSeq', async () => {
  const store = new InMemoryImStore();
  await store.upsertConversations([{ id: 'c1', contactId: null, providerId: 'claude', title: 'C1', lastMessagePreview: '', lastSeq: 1, lastActivityAt: 1, isPinned: false, isMuted: false }]);
  await applyFrame(store, { type: 'im:message', message: { id: 'a1', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: 'done', createdAt: 9 } });
  const conv = (await store.getConversations()).find((c) => c.id === 'c1');
  assert.equal(conv?.lastSeq, 2);
  assert.equal(conv?.lastMessagePreview, 'done');
  assert.equal((await store.getMessages('c1')).length, 1);
});

test('applyFrame im:read advances the device cursor and clears unread', async () => {
  const store = new InMemoryImStore();
  await store.upsertConversations([{ id: 'c1', contactId: null, providerId: 'claude', title: 'C1', lastMessagePreview: '', lastSeq: 3, lastActivityAt: 1, isPinned: false, isMuted: false }]);
  // Three Claude replies → three unread before reading.
  await store.upsertMessages([
    { id: 'a1', conversationId: 'c1', seq: 1, role: 'assistant', kind: 'result', content: '1', createdAt: 1 },
    { id: 'a2', conversationId: 'c1', seq: 2, role: 'assistant', kind: 'result', content: '2', createdAt: 2 },
    { id: 'a3', conversationId: 'c1', seq: 3, role: 'assistant', kind: 'result', content: '3', createdAt: 3 },
  ]);
  assert.equal((await computeUnread(store))['c1'], 3);
  await applyFrame(store, { type: 'im:read', conversationId: 'c1', deviceId: 'phone', lastReadSeq: 3 });
  assert.equal((await computeUnread(store))['c1'], 0);
});
