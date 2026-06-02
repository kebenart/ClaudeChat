# Web IM Client Implementation Plan (子系统 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Web 端按子系统 0 协议接入已完成的服务端 IM hub —— 本地优先(IndexedDB 镜像)同步会话/蒸馏消息/已读游标,驱动现有微信式 UI 的会话列表、跨端未读小红点、蒸馏聊天流。

**Architecture:** 新增一个与框架无关的 TS IM 客户端层(`src/services/im/`):`ImStore` 接口(`InMemoryImStore` 供测试 / `IndexedDbImStore` 供浏览器)+ 纯同步引擎(applySync/applyFrame/computeUnread)+ REST 客户端。再用一个 `IMContext` 把它接到现有 `WebSocketContext`(监听 `im:*` 帧)和现有微信组件(`AppContent` 喂 unread、`WeChatChatPane` 渲染蒸馏流)。纯逻辑用 Node test runner(`tsx --test`)对 `InMemoryImStore` 测试,无需引入前端测试框架。

**Tech Stack:** React 18 + Vite + TS(前端别名 `@/*` → `src/*`)。raw IndexedDB(不加依赖)。复用 `src/utils/api.js` 的 `authenticatedFetch` 和 `src/contexts/WebSocketContext.tsx` 的 `latestMessage`。测试:`npx tsx --tsconfig tsconfig.json --test "src/services/im/**/*.test.ts"`。

> **跨端已读语义(单用户 fork)**:服务端按 `(conversation_id, device_id)` 存每设备已读游标。本 fork 单用户,所以"在任一设备读了 → 各端红点都清":客户端取**所有设备游标的最大值**作为该会话的已读位置,`unread = max(0, conversation.lastSeq − maxReadSeqAcrossDevices)`。

---

## 服务端契约回顾(子系统 1 已实现,本计划消费)

- `GET /api/im/sync?since=<rev>` → `{ messages: WireMessage[], conversations: WireConversation[], readCursors: WireReadCursor[], cursor: number, hasMore: boolean }`。`cursor` 是全局 `rev` 游标(insert 和原地更新都自增,所以流式增长内容会被重新下发)。
- `GET /api/im/conversations/:id/messages?anchor=&numBefore=&numAfter=` → `{ messages: WireMessage[] }`(seq 升序窗口)。
- `POST /api/im/conversations/:id/read` body `{ deviceId, lastReadSeq }` → `{ ok: true }`,服务端广播 `im:read`。
- `POST /api/im/conversations/:id/state` body `{ isPinned?, isMuted? }`。
- `GET /api/im/conversations/:id/transcript?anchor=&numBefore=&numAfter=` / `.../transcript/blob/:entryId`(完整记录,后续任务)。
- WS 帧(现有 `/ws`,`useWebSocket().latestMessage`):
  - `im:message { message: WireMessage }`
  - `im:read { conversationId, deviceId, lastReadSeq }`
  - `im:poke { since }`(目前服务端未主动发,预留:收到则触发一次增量 sync)

**Wire 形状(来自 `server/services/im-events.service.ts` `serializeMessage` 与 `routes/im.js`):**
```
WireMessage   = { id: string; conversationId: string; seq: number; role: string; kind: string; content: string; createdAt: number; toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string } }
WireConversation = { id: string; contactId: string|null; providerId: string; title: string|null; lastMessagePreview: string|null; lastSeq: number; lastActivityAt: number; isPinned: boolean; isMuted: boolean }
WireReadCursor = { conversationId: string; deviceId: string; lastReadSeq: number }
```

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `src/services/im/protocol.ts` | Wire 类型 + 客户端态类型 + `im:*` 帧联合类型 | Create |
| `src/services/im/store.ts` | `ImStore` 接口 + `InMemoryImStore`(测试用) | Create |
| `src/services/im/syncEngine.ts` | 纯逻辑:applySync / applyFrame / computeUnread | Create |
| `src/services/im/indexedDbStore.ts` | `IndexedDbImStore`(raw IndexedDB,浏览器) | Create |
| `src/services/im/api.ts` | REST 客户端 + 纯 URL 构造 helper | Create |
| `src/services/im/deviceId.ts` | localStorage 持久 deviceId | Create |
| `src/contexts/IMContext.tsx` | React 胶水:store + 初始/增量 sync + WS 帧 → 暴露 useIM() | Create |
| `src/App.tsx` | 挂 `<IMProvider>`(WebSocketProvider 内) | Modify |
| `src/components/app/AppContent.tsx` | unread 来源切到 useIM();选中会话时 markRead | Modify |
| `src/components/wechat/WeChatChatPane.tsx` | 渲染 useIM() 的蒸馏消息流 + 灰色工具条 | Modify |
| 各 `*.test.ts` | store / syncEngine / api-url 的单测 | Create |

每个文件单一职责:`syncEngine` 是可独立测试的纯逻辑;`store` 抽象掉持久化;`IMContext` 只做 React 接线。

---

## Task 1: 协议类型 + ImStore 接口 + InMemoryImStore

**Files:**
- Create: `src/services/im/protocol.ts`
- Create: `src/services/im/store.ts`
- Test: `src/services/im/store.test.ts`

- [ ] **Step 1: 写协议类型 `src/services/im/protocol.ts`**

```ts
// Wire shapes (from server serializeMessage + /api/im routes).
export interface WireMessage {
  id: string;
  conversationId: string;
  seq: number;
  role: string;
  kind: string;
  content: string;
  createdAt: number;
  toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string };
}

export interface WireConversation {
  id: string;
  contactId: string | null;
  providerId: string;
  title: string | null;
  lastMessagePreview: string | null;
  lastSeq: number;
  lastActivityAt: number;
  isPinned: boolean;
  isMuted: boolean;
}

export interface WireReadCursor {
  conversationId: string;
  deviceId: string;
  lastReadSeq: number;
}

export interface SyncResponse {
  messages: WireMessage[];
  conversations: WireConversation[];
  readCursors: WireReadCursor[];
  cursor: number;
  hasMore: boolean;
}

// Incoming WS frames we care about.
export type ImFrame =
  | { type: 'im:message'; message: WireMessage }
  | { type: 'im:read'; conversationId: string; deviceId: string; lastReadSeq: number }
  | { type: 'im:poke'; since: number };

export function isImFrame(value: unknown): value is ImFrame {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { type?: unknown }).type === 'string' &&
    (value as { type: string }).type.startsWith('im:')
  );
}
```

- [ ] **Step 2: 写失败测试 `src/services/im/store.test.ts`**

```ts
import test from 'node:test';
import assert from 'node:assert/strict';

import { InMemoryImStore } from '@/services/im/store.js';

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

test('InMemoryImStore cursor and read cursors round-trip', async () => {
  const store = new InMemoryImStore();
  await store.setCursor(7);
  assert.equal(await store.getCursor(), 7);
  await store.setReadCursor('c1', 'devA', 3);
  await store.setReadCursor('c1', 'devB', 5);
  const cursors = await store.getReadCursorsFor('c1');
  assert.deepEqual(cursors.sort((a, b) => a.lastReadSeq - b.lastReadSeq).map((c) => c.lastReadSeq), [3, 5]);
});
```

- [ ] **Step 3: 运行确认失败**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/store.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 4: 实现 `src/services/im/store.ts`**

```ts
import type { WireConversation, WireMessage } from '@/services/im/protocol.js';

export interface StoredReadCursor {
  conversationId: string;
  deviceId: string;
  lastReadSeq: number;
}

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
  private readCursors = new Map<string, number>(); // `${convId} ${deviceId}` -> seq

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
    for (const m of messages) {
      let byId = this.messages.get(m.conversationId);
      if (!byId) {
        byId = new Map();
        this.messages.set(m.conversationId, byId);
      }
      byId.set(m.id, m);
    }
  }
  async getMessages(conversationId: string): Promise<WireMessage[]> {
    const byId = this.messages.get(conversationId);
    if (!byId) return [];
    return [...byId.values()].sort((a, b) => a.seq - b.seq);
  }
  async setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void> {
    const key = `${conversationId} ${deviceId}`;
    const prev = this.readCursors.get(key) ?? 0;
    this.readCursors.set(key, Math.max(prev, lastReadSeq));
  }
  async getReadCursorsFor(conversationId: string): Promise<StoredReadCursor[]> {
    return (await this.getAllReadCursors()).filter((c) => c.conversationId === conversationId);
  }
  async getAllReadCursors(): Promise<StoredReadCursor[]> {
    return [...this.readCursors.entries()].map(([key, lastReadSeq]) => {
      const [conversationId, deviceId] = key.split(' ');
      return { conversationId, deviceId, lastReadSeq };
    });
  }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/store.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 6: eslint + 提交**

```bash
npx eslint src/services/im/protocol.ts src/services/im/store.ts src/services/im/store.test.ts
git add src/services/im/protocol.ts src/services/im/store.ts src/services/im/store.test.ts
git commit -m "feat(im-web): protocol types + ImStore interface + in-memory store"
```

---

## Task 2: 同步引擎(纯逻辑核心)

**Files:**
- Create: `src/services/im/syncEngine.ts`
- Test: `src/services/im/syncEngine.test.ts`

- [ ] **Step 1: 写失败测试 `src/services/im/syncEngine.test.ts`**

```ts
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

test('computeUnread = lastSeq - max read seq across devices (single-user cross-device)', async () => {
  const store = new InMemoryImStore();
  await applySync(store, syncResp({
    conversations: [{ id: 'c1', contactId: null, providerId: 'claude', title: 'C1', lastMessagePreview: '', lastSeq: 5, lastActivityAt: 1, isPinned: false, isMuted: false }],
    readCursors: [
      { conversationId: 'c1', deviceId: 'phone', lastReadSeq: 5 }, // phone read everything
      { conversationId: 'c1', deviceId: 'desktop', lastReadSeq: 2 },
    ],
    cursor: 5,
  }));
  // Reading on the phone (max=5) clears the dot everywhere.
  const unread = await computeUnread(store);
  assert.equal(unread['c1'], 0);
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
  assert.equal((await computeUnread(store))['c1'], 3);
  await applyFrame(store, { type: 'im:read', conversationId: 'c1', deviceId: 'phone', lastReadSeq: 3 });
  assert.equal((await computeUnread(store))['c1'], 0);
});
```

- [ ] **Step 2: 运行确认失败**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/syncEngine.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现 `src/services/im/syncEngine.ts`**

```ts
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
 * Per-conversation unread = max(0, lastSeq - maxReadSeqAcrossDevices).
 * Single-user fork: reading on ANY device (the max cursor) clears the dot everywhere.
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
    unread[conv.id] = Math.max(0, conv.lastSeq - read);
  }
  return unread;
}
```

- [ ] **Step 4: 运行确认通过**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/syncEngine.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: eslint + 提交**

```bash
npx eslint src/services/im/syncEngine.ts src/services/im/syncEngine.test.ts
git add src/services/im/syncEngine.ts src/services/im/syncEngine.test.ts
git commit -m "feat(im-web): pure sync engine (applySync/applyFrame/computeUnread)"
```

---

## Task 3: REST 客户端 + 纯 URL 构造

**Files:**
- Create: `src/services/im/api.ts`
- Test: `src/services/im/api.test.ts`

URL/参数构造抽成纯函数单测;实际 fetch 走现有 `authenticatedFetch`(`src/utils/api.js`)只做薄封装。

- [ ] **Step 1: 写失败测试 `src/services/im/api.test.ts`**

```ts
import test from 'node:test';
import assert from 'node:assert/strict';

import { buildSyncUrl, buildMessagesUrl } from '@/services/im/api.js';

test('buildSyncUrl encodes the cursor', () => {
  assert.equal(buildSyncUrl(0), '/api/im/sync?since=0');
  assert.equal(buildSyncUrl(42), '/api/im/sync?since=42');
});

test('buildMessagesUrl encodes anchor/numBefore/numAfter and the conversation id', () => {
  assert.equal(buildMessagesUrl('c1', { numBefore: 40, numAfter: 0 }), '/api/im/conversations/c1/messages?numBefore=40&numAfter=0');
  assert.equal(
    buildMessagesUrl('a/b', { anchorSeq: 5, numBefore: 2, numAfter: 3 }),
    '/api/im/conversations/a%2Fb/messages?anchor=5&numBefore=2&numAfter=3'
  );
});
```

- [ ] **Step 2: 运行确认失败**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/api.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现 `src/services/im/api.ts`**

```ts
import { authenticatedFetch } from '@/utils/api.js';
import type { SyncResponse, WireMessage } from '@/services/im/protocol.js';

export function buildSyncUrl(since: number): string {
  return `/api/im/sync?since=${encodeURIComponent(String(since))}`;
}

export function buildMessagesUrl(
  conversationId: string,
  opts: { anchorSeq?: number; numBefore: number; numAfter: number }
): string {
  const params = new URLSearchParams();
  if (opts.anchorSeq !== undefined) params.set('anchor', String(opts.anchorSeq));
  params.set('numBefore', String(opts.numBefore));
  params.set('numAfter', String(opts.numAfter));
  return `/api/im/conversations/${encodeURIComponent(conversationId)}/messages?${params.toString()}`;
}

export async function fetchSync(since: number): Promise<SyncResponse> {
  const res = await authenticatedFetch(buildSyncUrl(since));
  if (!res.ok) throw new Error(`im sync failed: ${res.status}`);
  return (await res.json()) as SyncResponse;
}

export async function fetchMessages(
  conversationId: string,
  opts: { anchorSeq?: number; numBefore: number; numAfter: number }
): Promise<WireMessage[]> {
  const res = await authenticatedFetch(buildMessagesUrl(conversationId, opts));
  if (!res.ok) throw new Error(`im messages failed: ${res.status}`);
  const body = (await res.json()) as { messages: WireMessage[] };
  return body.messages ?? [];
}

export async function postRead(conversationId: string, deviceId: string, lastReadSeq: number): Promise<void> {
  await authenticatedFetch(`/api/im/conversations/${encodeURIComponent(conversationId)}/read`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ deviceId, lastReadSeq }),
  });
}

export async function postState(conversationId: string, state: { isPinned?: boolean; isMuted?: boolean }): Promise<void> {
  await authenticatedFetch(`/api/im/conversations/${encodeURIComponent(conversationId)}/state`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(state),
  });
}
```

> **校验**:打开 `src/utils/api.js` 确认 `authenticatedFetch` 是具名导出且签名为 `(url, options?) => Promise<Response>`。若它是默认导出或包了 `.json()`,按真实签名调整本文件的调用(保持 `build*Url` 纯函数不变)。

- [ ] **Step 4: 运行确认通过**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/api.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: eslint + 提交**

```bash
npx eslint src/services/im/api.ts src/services/im/api.test.ts
git add src/services/im/api.ts src/services/im/api.test.ts
git commit -m "feat(im-web): REST client + pure URL builders"
```

---

## Task 4: deviceId + IndexedDbImStore(浏览器持久化)

**Files:**
- Create: `src/services/im/deviceId.ts`
- Create: `src/services/im/indexedDbStore.ts`

无 Node 端 IndexedDB,故本任务以 **typecheck 通过 + 接口契合** 为验收(纯逻辑已在 Task 1/2 用 InMemoryImStore 覆盖)。`IndexedDbImStore` 必须 `implements ImStore`,保证与已测引擎兼容。

- [ ] **Step 1: 实现 `src/services/im/deviceId.ts`**

```ts
const DEVICE_ID_KEY = 'im:device-id';

/** Stable per-browser device id (random uuid), persisted in localStorage. */
export function getDeviceId(): string {
  try {
    let id = localStorage.getItem(DEVICE_ID_KEY);
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem(DEVICE_ID_KEY, id);
    }
    return id;
  } catch {
    // localStorage disabled — fall back to an ephemeral id for this page load.
    return crypto.randomUUID();
  }
}
```

- [ ] **Step 2: 实现 `src/services/im/indexedDbStore.ts`**

```ts
import type { ImStore, StoredReadCursor } from '@/services/im/store.js';
import type { WireConversation, WireMessage } from '@/services/im/protocol.js';

const DB_NAME = 'im-client';
const DB_VERSION = 1;
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
      if (!db.objectStoreNames.contains(STORE_META)) db.createObjectStore(STORE_META);
      if (!db.objectStoreNames.contains(STORE_CONVERSATIONS)) db.createObjectStore(STORE_CONVERSATIONS, { keyPath: 'id' });
      if (!db.objectStoreNames.contains(STORE_MESSAGES)) {
        const ms = db.createObjectStore(STORE_MESSAGES, { keyPath: 'id' });
        ms.createIndex('byConversation', 'conversationId', { unique: false });
      }
      if (!db.objectStoreNames.contains(STORE_READ_CURSORS)) {
        db.createObjectStore(STORE_READ_CURSORS, { keyPath: ['conversationId', 'deviceId'] });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
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
    if (!this.dbPromise) this.dbPromise = openDb();
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
    const tx = db.transaction(STORE_READ_CURSORS, 'readwrite');
    const os = tx.objectStore(STORE_READ_CURSORS);
    const existing = (await reqResult(os.get([conversationId, deviceId]))) as StoredReadCursor | undefined;
    const next = Math.max(existing?.lastReadSeq ?? 0, lastReadSeq);
    os.put({ conversationId, deviceId, lastReadSeq: next });
    await txDone(tx);
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
```

- [ ] **Step 3: typecheck + eslint**

Run: `npm run typecheck` (expect clean) and `npx eslint src/services/im/deviceId.ts src/services/im/indexedDbStore.ts`
Expected: clean. If the root tsconfig lacks DOM lib types for IndexedDB, confirm `lib` includes `DOM` (it does for a Vite frontend) — do NOT add a custom lib config.

- [ ] **Step 4: 提交**

```bash
git add src/services/im/deviceId.ts src/services/im/indexedDbStore.ts
git commit -m "feat(im-web): IndexedDB store + persistent device id"
```

---

## Task 5: IMContext + useIM 钩子,挂进 App

**Files:**
- Create: `src/contexts/IMContext.tsx`
- Modify: `src/App.tsx`

- [ ] **Step 1: 实现 `src/contexts/IMContext.tsx`**

```tsx
import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import { useWebSocket } from '@/contexts/WebSocketContext';
import { IndexedDbImStore } from '@/services/im/indexedDbStore';
import type { ImStore } from '@/services/im/store';
import { applySync, applyFrame, computeUnread } from '@/services/im/syncEngine';
import { fetchSync, fetchMessages, postRead } from '@/services/im/api';
import { getDeviceId } from '@/services/im/deviceId';
import { isImFrame } from '@/services/im/protocol';
import type { WireConversation, WireMessage } from '@/services/im/protocol';

interface IMContextValue {
  conversations: WireConversation[];
  unreadByConversation: Record<string, number>;
  getMessages: (conversationId: string) => Promise<WireMessage[]>;
  markRead: (conversationId: string) => Promise<void>;
}

const IMContext = createContext<IMContextValue | null>(null);

export function IMProvider({ children }: { children: ReactNode }) {
  const { latestMessage } = useWebSocket();
  const storeRef = useRef<ImStore>(null as unknown as ImStore);
  if (storeRef.current === null) storeRef.current = new IndexedDbImStore();
  const deviceId = useMemo(() => getDeviceId(), []);

  const [conversations, setConversations] = useState<WireConversation[]>([]);
  const [unreadByConversation, setUnread] = useState<Record<string, number>>({});

  // Recompute the reactive snapshot from the store after any mutation.
  const refresh = useRef(async () => {
    const store = storeRef.current;
    const [convs, unread] = await Promise.all([store.getConversations(), computeUnread(store)]);
    convs.sort((a, b) => (b.isPinned ? 1 : 0) - (a.isPinned ? 1 : 0) || b.lastActivityAt - a.lastActivityAt);
    setConversations(convs);
    setUnread(unread);
  }).current;

  // Initial + paged sync on mount.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const store = storeRef.current;
      let since = await store.getCursor();
      // Pull until caught up.
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const resp = await fetchSync(since);
        if (cancelled) return;
        await applySync(store, resp);
        since = resp.cursor;
        if (!resp.hasMore) break;
      }
      await refresh();
    })().catch((err) => console.error('IM initial sync failed', err));
    return () => { cancelled = true; };
  }, [refresh]);

  // Apply incoming WS frames.
  useEffect(() => {
    if (!latestMessage || !isImFrame(latestMessage)) return;
    (async () => {
      if (latestMessage.type === 'im:poke') {
        const store = storeRef.current;
        const resp = await fetchSync(await store.getCursor());
        await applySync(store, resp);
      } else {
        await applyFrame(storeRef.current, latestMessage);
      }
      await refresh();
    })().catch((err) => console.error('IM frame apply failed', err));
  }, [latestMessage, refresh]);

  const value = useMemo<IMContextValue>(() => ({
    conversations,
    unreadByConversation,
    getMessages: (conversationId: string) => storeRef.current.getMessages(conversationId),
    markRead: async (conversationId: string) => {
      const store = storeRef.current;
      const conv = (await store.getConversations()).find((c) => c.id === conversationId);
      const seq = conv?.lastSeq ?? 0;
      await store.setReadCursor(conversationId, deviceId, seq);
      await refresh();
      await postRead(conversationId, deviceId, seq); // broadcasts im:read → other devices clear
    },
  }), [conversations, unreadByConversation, deviceId, refresh]);

  return <IMContext.Provider value={value}>{children}</IMContext.Provider>;
}

export function useIM(): IMContextValue {
  const ctx = useContext(IMContext);
  if (!ctx) throw new Error('useIM must be used within <IMProvider>');
  return ctx;
}
```

> **校验**:打开 `src/contexts/WebSocketContext.tsx` 确认 `useWebSocket()` 返回 `{ latestMessage }` 且导出名为 `useWebSocket`。若名称不同(如 `useWebSocketContext`),按真实导出调整 import。

- [ ] **Step 2: 挂进 `src/App.tsx`** —— 在 `WebSocketProvider` 内、业务 Provider 外包一层 `IMProvider`。找到 `<WebSocketProvider>...</WebSocketProvider>` 区域,在其子树最外层加入:

```tsx
import { IMProvider } from '@/contexts/IMContext';
// ...
<WebSocketProvider>
  <IMProvider>
    {/* existing children (PluginsProvider ... etc.) */}
  </IMProvider>
</WebSocketProvider>
```

(保持其余 Provider 顺序不变,只把现有 WebSocketProvider 的直接子树用 IMProvider 包一层。)

- [ ] **Step 3: typecheck + eslint + 提交**

```bash
npm run typecheck
npx eslint src/contexts/IMContext.tsx src/App.tsx
git add src/contexts/IMContext.tsx src/App.tsx
git commit -m "feat(im-web): IMContext sync engine glue + provider wiring"
```

---

## Task 6: 会话列表未读 / 小红点切到 IM 数据源

**Files:**
- Modify: `src/components/app/AppContent.tsx`

把传给 `WeChatSidebar` 的 `unreadBySession` 改由 `useIM().unreadByConversation` 提供(会话 id == session id),并在选中会话时调用 `markRead`。保留现有 ad-hoc 计数作为回退不再必要 —— 用 IM 数据覆盖。

- [ ] **Step 1: 在 AppContent 顶部引入 useIM**

```tsx
import { useIM } from '@/contexts/IMContext';
// 在 AppContentInner() 组件体内:
const { unreadByConversation, markRead } = useIM();
```

- [ ] **Step 2: 用 IM 未读覆盖传给 sidebar 的 prop**

找到传给 `WeChatSidebar` 的 `unreadBySession={...}`(当前来自本地 ad-hoc state,见 AppContent 约 159/308 行附近),改为:

```tsx
unreadBySession={unreadByConversation}
```

- [ ] **Step 3: 选中会话时清红点**

找到会话选中处理(`onSelectSession` / `onSessionSelect`,当前会删除本地 unread key,约 273 行附近),在其中加入:

```tsx
void markRead(sessionId);
```

(保留既有导航逻辑;只追加这一行。`sessionId` 为该处理函数已有的入参名,按真实参数名使用。)

- [ ] **Step 4: typecheck + eslint + 提交**

```bash
npm run typecheck
npx eslint src/components/app/AppContent.tsx
git add src/components/app/AppContent.tsx
git commit -m "feat(im-web): drive sidebar unread/red-dot from IM sync + mark read on open"
```

---

## Task 7: 聊天窗口渲染 IM 蒸馏消息流

**Files:**
- Modify: `src/components/wechat/WeChatChatPane.tsx`

让聊天窗口在选中会话时从 `useIM().getMessages(sessionId)` 取蒸馏消息渲染(覆盖现有 `/api/providers/.../messages` 取数路径),并在收到 `im:message`(经 IMContext 刷新)后更新。蒸馏消息映射到现有 `WeChatMessage`,`toolTrace` 渲染为灰色折叠小条。

- [ ] **Step 1: 引入 useIM 并加载会话蒸馏消息**

在 `WeChatChatPane` 组件体内加入:

```tsx
import { useIM } from '@/contexts/IMContext';
import { useIM as _useIM } from '@/contexts/IMContext'; // (单一 import 即可,勿重复)
// ...
const { getMessages, conversations } = useIM();
const [imMessages, setImMessages] = useState<WeChatMessage[]>([]);

useEffect(() => {
  if (!session?.id) { setImMessages([]); return; }
  let cancelled = false;
  void getMessages(session.id).then((rows) => {
    if (cancelled) return;
    setImMessages(rows.map((m) => ({
      id: m.id,
      role: (m.role === 'assistant' || m.role === 'user' || m.role === 'system') ? m.role : 'assistant',
      content: m.content,
      createdAt: new Date(m.createdAt),
      // toolTrace → 灰色折叠小条的数据;在 bubble 下方渲染
      toolTraceCount: m.toolTrace?.count ?? 0,
    } as WeChatMessage & { toolTraceCount?: number })));
  });
  return () => { cancelled = true; };
  // conversations changes when IMContext refreshes after an im:message frame.
}, [session?.id, getMessages, conversations]);
```

- [ ] **Step 2: 渲染 imMessages,并在工具计数>0 时显示灰色小条**

把消息列表渲染源从原 `messages` 切到 `imMessages`(保留滚动容器与气泡组件)。在每个 assistant 气泡下方,当 `toolTraceCount > 0` 时渲染:

```tsx
{(msg as { toolTraceCount?: number }).toolTraceCount ? (
  <div className="ml-[42px] mt-1 text-[11px] text-zinc-400 dark:text-zinc-500">
    执行了 {(msg as { toolTraceCount?: number }).toolTraceCount} 个操作
  </div>
) : null}
```

(灰色小条 MVP 先只显示计数;点开看完整记录在 Task 8 接入。)

- [ ] **Step 3: 手动验证(无前端测试运行器)**

Run: `npm run dev`,登录后打开一个会话,确认:列表显示会话 + 红点;打开会话红点清除;在另一处(或 CLI)产生新 Claude 回复时,会话冒出新气泡 + 列表红点(若非当前会话)。

- [ ] **Step 4: typecheck + eslint + 提交**

```bash
npm run typecheck
npx eslint src/components/wechat/WeChatChatPane.tsx
git add src/components/wechat/WeChatChatPane.tsx
git commit -m "feat(im-web): render distilled IM message stream in chat pane"
```

---

## Task 8: "查看完整记录"入口(原始 transcript)

**Files:**
- Modify: `src/services/im/api.ts`(加 transcript 取数)
- Modify: `src/components/wechat/WeChatChatPane.tsx`(灰色小条/标题栏入口 → 弹层显示分页 transcript)

- [ ] **Step 1: api.ts 加 transcript 取数 + 纯 URL 测试**

在 `src/services/im/api.test.ts` 追加:

```ts
import { buildTranscriptUrl } from '@/services/im/api.js';

test('buildTranscriptUrl encodes paging', () => {
  assert.equal(buildTranscriptUrl('c1', { numBefore: 0, numAfter: 40 }), '/api/im/conversations/c1/transcript?numBefore=0&numAfter=40');
});
```

在 `src/services/im/api.ts` 追加:

```ts
export interface TranscriptEntry { id: string; type: string; summary: string; hasBlob: boolean }

export function buildTranscriptUrl(
  conversationId: string,
  opts: { anchor?: string; numBefore: number; numAfter: number }
): string {
  const params = new URLSearchParams();
  if (opts.anchor !== undefined) params.set('anchor', opts.anchor);
  params.set('numBefore', String(opts.numBefore));
  params.set('numAfter', String(opts.numAfter));
  return `/api/im/conversations/${encodeURIComponent(conversationId)}/transcript?${params.toString()}`;
}

export async function fetchTranscript(
  conversationId: string,
  opts: { anchor?: string; numBefore: number; numAfter: number }
): Promise<{ entries: TranscriptEntry[]; hasMoreBefore: boolean; hasMoreAfter: boolean }> {
  const res = await authenticatedFetch(buildTranscriptUrl(conversationId, opts));
  if (!res.ok) throw new Error(`im transcript failed: ${res.status}`);
  return (await res.json()) as { entries: TranscriptEntry[]; hasMoreBefore: boolean; hasMoreAfter: boolean };
}
```

- [ ] **Step 2: 运行 api 测试确认通过**

Run: `npx tsx --tsconfig tsconfig.json --test src/services/im/api.test.ts`
Expected: PASS(3 tests)

- [ ] **Step 3: 聊天窗口标题栏加"完整记录"入口 → 弹层**

在 `WeChatChatPane` 标题栏(已有 `onShowSessionInfo` 之类的占位)加一个按钮,点开一个简单弹层组件,首屏 `fetchTranscript(session.id, { numBefore: 0, numAfter: 40 })`,列出 `entries`(每条显示 `type` + `summary`),向上滚动用 `entries[0].id` 作 `anchor` 续拉 `numBefore`。`hasBlob` 的条目右侧给"展开"按钮(调用 `/transcript/blob/:entryId`,本任务先只显示占位提示,完整 blob 拉取留作后续)。

(此弹层为新建小组件 `src/components/wechat/WeChatTranscriptSheet.tsx`,纯展示 + 分页,不改其它逻辑。)

- [ ] **Step 4: typecheck + eslint + 提交**

```bash
npm run typecheck
npx eslint src/services/im/api.ts src/services/im/api.test.ts src/components/wechat/WeChatChatPane.tsx src/components/wechat/WeChatTranscriptSheet.tsx
git add src/services/im/api.ts src/services/im/api.test.ts src/components/wechat/WeChatChatPane.tsx src/components/wechat/WeChatTranscriptSheet.tsx
git commit -m "feat(im-web): full raw transcript viewer (paged)"
```

---

## Self-Review

**Spec coverage(对照地基 spec §12 Web 端落地 + §6/§11):**
- 本地优先 IndexedDB 镜像 → Task 4(IndexedDbImStore)✅
- 同步协议(/sync rev 游标增量 + WS 帧 + 上报已读)→ Task 2(引擎)+ Task 3(REST)+ Task 5(接线)✅
- 跨端未读/小红点(读任一端清各端)→ Task 2 `computeUnread`(max read across devices)+ Task 6 ✅
- 蒸馏聊天流 + 灰色折叠工具条 → Task 7 ✅
- 完整记录分页查看 → Task 8 ✅
- 复用现有微信 UI(不重写)→ Task 6/7 只增量接线 ✅

**Placeholder scan:** 纯逻辑任务(1/2/3)含完整可运行代码 + 测试。React 接线任务(5/6/7/8)给出实际要加的代码块 + 明确的接入点(并标注"按真实导出/参数名校验"),因为现有组件较大、需就地接线 —— 这是对既有代码的接入指引,非占位。

**Type consistency:** `WireMessage`/`WireConversation`/`SyncResponse`(Task 1)贯穿 Task 2/3/5;`ImStore` 接口(Task 1)被 `InMemoryImStore`(Task 1)与 `IndexedDbImStore`(Task 4)实现,被 `syncEngine`(Task 2)与 `IMContext`(Task 5)消费;`computeUnread` 返回 `Record<string,number>` 直接喂 `WeChatSidebar.unreadBySession`(Task 6)。一致。

**已知简化(非阻塞):** 大 blob 完整拉取(Task 8 Step 3 仅占位);发送消息仍走现有 chat WS 路径(子系统 1 说明:发送=现有 WS 链路,本计划不新造发送);消息分页向上翻页(messages 端点已具备,UI 暂只首屏,后续接 `fetchMessages` anchor 续拉)。

---

## Execution Handoff

见下方对话 —— 给出执行方式选择。
