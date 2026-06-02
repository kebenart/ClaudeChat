import type { WireConversation, WireMessage } from '@/services/im/protocol.js';

export interface StoredReadCursor {
  conversationId: string;
  deviceId: string;
  lastReadSeq: number;
}

/**
 * Hard cap on how many messages the in-memory store keeps per conversation.
 * Without this the messages Map grows unbounded across syncs/WS frames. Safe
 * because the UI only renders recent messages (older history lazy-loads from
 * the server via fetchMessages / the transcript) and unread counts only look at
 * reply messages above the read cursor, which always live in the recent tail.
 * We keep the highest-seq N and evict the lowest-seq entries.
 */
export const MAX_MESSAGES_PER_CONVERSATION = 300;

/**
 * Persistence abstraction for the IM client. Two implementations:
 *  - InMemoryImStore (this file) — used by unit tests.
 *  - IndexedDbImStore — used in the browser.
 * All methods are async so the IndexedDB impl fits the same shape.
 */
export interface ImStore {
  getCursor(): Promise<number>;
  setCursor(cursor: number): Promise<void>;
  upsertConversations(conversations: WireConversation[]): Promise<void>;
  getConversations(): Promise<WireConversation[]>;
  upsertMessages(messages: WireMessage[]): Promise<void>;
  getMessages(conversationId: string): Promise<WireMessage[]>;
  setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void>;
  getReadCursorsFor(conversationId: string): Promise<StoredReadCursor[]>;
  getAllReadCursors(): Promise<StoredReadCursor[]>;
}

export class InMemoryImStore implements ImStore {
  private cursor = 0;
  private conversations = new Map<string, WireConversation>();
  private messages = new Map<string, Map<string, WireMessage>>(); // convId -> (msgId -> msg)
  private readCursors = new Map<string, number>(); // `${convId} ${deviceId}` -> seq

  async getCursor(): Promise<number> {
    return this.cursor;
  }
  async setCursor(cursor: number): Promise<void> {
    this.cursor = cursor;
  }
  async upsertConversations(conversations: WireConversation[]): Promise<void> {
    for (const c of conversations) this.conversations.set(c.id, c);
  }
  async getConversations(): Promise<WireConversation[]> {
    return [...this.conversations.values()];
  }
  async upsertMessages(messages: WireMessage[]): Promise<void> {
    const touched = new Set<string>();
    for (const m of messages) {
      let byId = this.messages.get(m.conversationId);
      if (!byId) {
        byId = new Map();
        this.messages.set(m.conversationId, byId);
      }
      byId.set(m.id, m);
      touched.add(m.conversationId);
    }
    // Bound each touched conversation to the most-recent N messages by seq,
    // evicting the lowest-seq entries. Keeps the store from growing unbounded.
    for (const convId of touched) this.capConversation(convId);
  }

  /** Evict the lowest-seq messages so a conversation keeps at most N entries. */
  private capConversation(conversationId: string): void {
    const byId = this.messages.get(conversationId);
    if (!byId || byId.size <= MAX_MESSAGES_PER_CONVERSATION) return;
    // Sort ascending by seq; the oldest (lowest-seq) entries at the front are
    // the ones to drop.
    const sorted = [...byId.values()].sort((a, b) => a.seq - b.seq);
    const dropCount = sorted.length - MAX_MESSAGES_PER_CONVERSATION;
    for (let i = 0; i < dropCount; i++) byId.delete(sorted[i].id);
  }
  async getMessages(conversationId: string): Promise<WireMessage[]> {
    const byId = this.messages.get(conversationId);
    if (!byId) return [];
    return [...byId.values()].sort((a, b) => a.seq - b.seq);
  }
  async setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void> {
    const key = `${conversationId} ${deviceId}`;
    const prev = this.readCursors.get(key) ?? 0;
    this.readCursors.set(key, Math.max(prev, lastReadSeq));
  }
  async getReadCursorsFor(conversationId: string): Promise<StoredReadCursor[]> {
    return (await this.getAllReadCursors()).filter((c) => c.conversationId === conversationId);
  }
  async getAllReadCursors(): Promise<StoredReadCursor[]> {
    return [...this.readCursors.entries()].map(([key, lastReadSeq]) => {
      const [conversationId, deviceId] = key.split(' ');
      return { conversationId, deviceId, lastReadSeq };
    });
  }
}
