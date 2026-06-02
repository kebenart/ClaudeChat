import type { ImStore } from '@/services/im/store.js';
import type { ImFrame, SyncResponse, WireConversation } from '@/services/im/protocol.js';

/** Apply a full or incremental /sync response to the store. */
export async function applySync(store: ImStore, resp: SyncResponse): Promise<void> {
  if (resp.conversations.length > 0) await store.upsertConversations(resp.conversations);
  if (resp.messages.length > 0) await store.upsertMessages(resp.messages);
  for (const rc of resp.readCursors) {
    await store.setReadCursor(rc.conversationId, rc.deviceId, rc.lastReadSeq);
  }
  await store.setCursor(resp.cursor);
}

/** Apply one incoming WS frame. Returns true if anything changed. */
export async function applyFrame(store: ImStore, frame: ImFrame): Promise<boolean> {
  if (frame.type === 'im:message') {
    const m = frame.message;
    await store.upsertMessages([m]);
    // Keep the conversation's lastSeq/preview in step with the newest message.
    const convs = await store.getConversations();
    const conv = convs.find((c) => c.id === m.conversationId);
    if (conv && m.seq >= conv.lastSeq) {
      const updated: WireConversation = {
        ...conv,
        lastSeq: m.seq,
        lastMessagePreview: m.content.slice(0, 120),
        lastActivityAt: m.createdAt,
      };
      await store.upsertConversations([updated]);
    }
    return true;
  }
  if (frame.type === 'im:read') {
    await store.setReadCursor(frame.conversationId, frame.deviceId, frame.lastReadSeq);
    return true;
  }
  // im:poke carries no data — the caller decides to trigger an incremental sync.
  return false;
}

/**
 * A message kind representing a Claude *reply turn* the user should see. The
 * IM-hub distiller emits one assistant row per turn with kind `result` (normal)
 * or `error` (failed) — the user's own sends are `role:'user', kind:'text'`.
 * Counting these instead of `lastSeq - read` stops the badge inflating by the
 * user's own messages and empty tool/meta frames.
 */
const REPLY_KINDS = new Set(['result', 'error', 'text']);

/**
 * Per-conversation unread = number of Claude reply messages above the max read
 * cursor across devices. Single-user fork: reading on ANY device (the max
 * cursor) clears the dot everywhere.
 */
export async function computeUnread(store: ImStore): Promise<Record<string, number>> {
  const conversations = await store.getConversations();
  const cursors = await store.getAllReadCursors();
  const maxReadByConv = new Map<string, number>();
  for (const c of cursors) {
    maxReadByConv.set(c.conversationId, Math.max(maxReadByConv.get(c.conversationId) ?? 0, c.lastReadSeq));
  }
  const unread: Record<string, number> = {};
  for (const conv of conversations) {
    const read = maxReadByConv.get(conv.id) ?? 0;
    const msgs = await store.getMessages(conv.id);
    // Only Claude's replies count — never the user's own messages (role 'user').
    unread[conv.id] = msgs.filter(
      (m) => m.seq > read && m.role === 'assistant' && REPLY_KINDS.has(m.kind),
    ).length;
  }
  return unread;
}
