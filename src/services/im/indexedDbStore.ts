import type { ImStore, StoredReadCursor } from '@/services/im/store.js';
import type { WireConversation, WireMessage } from '@/services/im/protocol.js';

const DB_NAME = 'im-client';
// v3: wipe the local cache once (see onupgradeneeded). Early-dev builds cached
// distilled messages from since-fixed distill/dedup logic that never re-synced,
// so the chat history showed stale/wrong content. The open is also made robust
// against a blocked upgrade (another tab holding an old version) which would
// otherwise hang the DB connection forever and stick the chat on "加载中".
const DB_VERSION = 3;
const STORE_META = 'meta';
const STORE_CONVERSATIONS = 'conversations';
const STORE_MESSAGES = 'messages';
const STORE_READ_CURSORS = 'readCursors';
const CURSOR_KEY = 'cursor';

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      // Drop any existing stores (clears stale cached data + the sync cursor)
      // then recreate empty — forces a clean full re-sync from the server.
      for (const name of Array.from(db.objectStoreNames)) {
        db.deleteObjectStore(name);
      }
      db.createObjectStore(STORE_META);
      db.createObjectStore(STORE_CONVERSATIONS, { keyPath: 'id' });
      const ms = db.createObjectStore(STORE_MESSAGES, { keyPath: 'id' });
      ms.createIndex('byConversation', 'conversationId', { unique: false });
      db.createObjectStore(STORE_READ_CURSORS, { keyPath: ['conversationId', 'deviceId'] });
    };
    req.onsuccess = () => {
      const db = req.result;
      // If another tab later requests a newer version, close this connection so
      // its upgrade isn't blocked (which would hang that tab's DB forever).
      db.onversionchange = () => db.close();
      resolve(db);
    };
    req.onerror = () => reject(req.error);
    // A pre-existing connection (e.g. an old tab) is blocking this upgrade.
    // Reject instead of hanging so callers fail fast and the UI doesn't stick
    // on a loading spinner; reloading after closing the other tab recovers.
    req.onblocked = () => reject(new Error('IndexedDB upgrade blocked (close other tabs and reload)'));
  });
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

function reqResult<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export class IndexedDbImStore implements ImStore {
  private dbPromise: Promise<IDBDatabase> | null = null;

  private db(): Promise<IDBDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = openDb().catch((err) => {
        // Don't cache a failed open (e.g. a transient block) — let the next
        // call retry instead of permanently wedging every store operation.
        this.dbPromise = null;
        throw err;
      });
    }
    return this.dbPromise;
  }

  async getCursor(): Promise<number> {
    const db = await this.db();
    const tx = db.transaction(STORE_META, 'readonly');
    const value = await reqResult(tx.objectStore(STORE_META).get(CURSOR_KEY));
    return typeof value === 'number' ? value : 0;
  }

  async setCursor(cursor: number): Promise<void> {
    const db = await this.db();
    const tx = db.transaction(STORE_META, 'readwrite');
    tx.objectStore(STORE_META).put(cursor, CURSOR_KEY);
    await txDone(tx);
  }

  async upsertConversations(conversations: WireConversation[]): Promise<void> {
    const db = await this.db();
    const tx = db.transaction(STORE_CONVERSATIONS, 'readwrite');
    const os = tx.objectStore(STORE_CONVERSATIONS);
    for (const c of conversations) os.put(c);
    await txDone(tx);
  }

  async getConversations(): Promise<WireConversation[]> {
    const db = await this.db();
    const tx = db.transaction(STORE_CONVERSATIONS, 'readonly');
    return (await reqResult(tx.objectStore(STORE_CONVERSATIONS).getAll())) as WireConversation[];
  }

  async upsertMessages(messages: WireMessage[]): Promise<void> {
    const db = await this.db();
    const tx = db.transaction(STORE_MESSAGES, 'readwrite');
    const os = tx.objectStore(STORE_MESSAGES);
    for (const m of messages) os.put(m);
    await txDone(tx);
  }

  async getMessages(conversationId: string): Promise<WireMessage[]> {
    const db = await this.db();
    const tx = db.transaction(STORE_MESSAGES, 'readonly');
    const idx = tx.objectStore(STORE_MESSAGES).index('byConversation');
    const rows = (await reqResult(idx.getAll(IDBKeyRange.only(conversationId)))) as WireMessage[];
    return rows.sort((a, b) => a.seq - b.seq);
  }

  async setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void> {
    const db = await this.db();
    // Read in a readonly tx, then write in a fresh readwrite tx. Doing the
    // get→await→put on one tx can hit TransactionInactiveError in some browsers
    // because the tx auto-commits once the first request settles and control
    // yields to the microtask queue.
    const readTx = db.transaction(STORE_READ_CURSORS, 'readonly');
    const existing = (await reqResult(
      readTx.objectStore(STORE_READ_CURSORS).get([conversationId, deviceId])
    )) as StoredReadCursor | undefined;
    const next = Math.max(existing?.lastReadSeq ?? 0, lastReadSeq);

    const writeTx = db.transaction(STORE_READ_CURSORS, 'readwrite');
    writeTx.objectStore(STORE_READ_CURSORS).put({ conversationId, deviceId, lastReadSeq: next });
    await txDone(writeTx);
  }

  async getReadCursorsFor(conversationId: string): Promise<StoredReadCursor[]> {
    return (await this.getAllReadCursors()).filter((c) => c.conversationId === conversationId);
  }

  async getAllReadCursors(): Promise<StoredReadCursor[]> {
    const db = await this.db();
    const tx = db.transaction(STORE_READ_CURSORS, 'readonly');
    return (await reqResult(tx.objectStore(STORE_READ_CURSORS).getAll())) as StoredReadCursor[];
  }
}
