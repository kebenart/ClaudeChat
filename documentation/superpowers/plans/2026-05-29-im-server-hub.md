# Server IM Hub Implementation Plan (子系统 0 + 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Node 服务端实现 IM hub——把 Claude 的 `*.jsonl` 蒸馏成"正常聊天"消息流、分配跨端稳定 seq、提供规范化同步 REST + WS 推送，作为多端 IM 架构的地基。

**Architecture:** 方案 C 两层存储。jsonl 仍是消息源真相；新增 IM 状态库（SQLite，走现有 migrations）只存蒸馏消息 + 已读游标 + 会话元数据。蒸馏服务把每个 session 的 jsonl 解析为消息（剔除 tool/thinking，工具折叠为 toolTrace），分配全局自增 ingest id（同步游标）+ 每会话 seq（排序/已读基准）。同步 REST 走游标增量；WS 复用现有 `connectedClients` 广播 `im:*` 事件。

**Tech Stack:** TypeScript（ESM），`better-sqlite3`，Express，`ws`，Node 内置 test runner（`tsx --tsconfig server/tsconfig.json --test`）。后端路径别名 `@/*` → `server/*`。

> **认证说明**：项目处于测试阶段，认证已注释/跳过。本计划路由按现有 `authenticateToken` 中间件挂载位预留，但 deviceId 由请求体显式传入，测试不依赖登录态。

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `server/modules/database/schema.ts` | 新增 3 张 IM 表的 SQL 常量 | Modify |
| `server/modules/database/migrations.ts` | 在 `runMigrations` 末尾创建 IM 表 + 索引 | Modify |
| `server/modules/database/repositories/im.db.ts` | IM 状态库读写（会话/消息/已读/同步游标） | Create |
| `server/modules/database/index.ts` | barrel 导出 `imDb` | Modify |
| `server/services/im-distill.service.ts` | 纯函数：jsonl 条目 → 蒸馏消息（蒸馏规则核心） | Create |
| `server/services/im-ingest.service.ts` | 读 session jsonl → 蒸馏 → 幂等落库 + 分配 seq | Create |
| `server/services/im-events.service.ts` | 构造并广播 `im:*` WS 事件 | Create |
| `server/routes/im.js` | 同步 REST 端点（sync/messages/read/state/transcript/blob/send） | Create |
| `server/index.js` | 挂载 `/api/im` 路由 | Modify |
| 各 `*.test.ts` | 对应单测 | Create |

每个文件单一职责：`im-distill` 是可独立测试的纯蒸馏逻辑；`im-ingest` 负责持久化与 seq；`im-events` 只管 WS 帧；`routes/im.js` 只做 HTTP 适配。

---

## 共享类型（贯穿全计划，签名必须一致）

**规范位置（已迁移）：** `RawJsonlEntry`、`DistilledKind`、`DistilledMessage` 以及三个 `Im*Row` 接口（`ImMessageRow`、`ImConversationRow`、`ImReadCursorRow`）现在全部定义在 **`server/shared/types.ts`**（classified 为 `backend-shared-type-contract`，允许所有 `server/modules/*` 和 `server/services/*` 用 `import type` 引用，不触发 boundaries 错误）。

- `server/services/im-distill.service.ts` 从 `@/shared/types.js` import 后 re-export，现有消费方/测试无需改导入路径。
- `server/modules/database/repositories/im.db.ts` 同理 re-export 三个 `Im*Row` 类型，`insertMessages` 参数类型直接用 `DistilledMessage`。
- Tasks 4/5/6 中凡需引用这些类型，**优先** `import type { … } from '@/shared/types.js'`；ergonomic 场景可继续从 `im-distill.service.js` / `im.db.js` re-export 路径引入。

```ts
// 规范签名（定义在 server/shared/types.ts）
export interface RawJsonlEntry {
  type: string;                               // 'user' | 'assistant' | 'system' | 'ai-title' | ...
  message?: { role?: string; content?: unknown };
  uuid?: string;
  timestamp?: string;                         // ISO string
  isError?: boolean;
}

export type DistilledKind = 'text' | 'result' | 'question' | 'plan' | 'error';

export interface DistilledMessage {
  sourceId: string;                           // 稳定 id（源自 jsonl uuid），幂等键
  role: 'user' | 'assistant' | 'system';
  kind: DistilledKind;
  content: string;
  createdAt: number;                          // epoch ms
  toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string };
}
```

IM 表列与协议字段映射（见 spec §7/§9）：`im_messages.pk`(全局自增=同步游标) / `source_id`(=DistilledMessage.sourceId) / `seq`(每会话序号)。

---

## Task 1: IM 状态库表结构 + 迁移

**Files:**
- Modify: `server/modules/database/schema.ts`
- Modify: `server/modules/database/migrations.ts:452-453`（`LAST_SCANNED_AT_SQL` 之后、成功 log 之前）
- Test: `server/modules/database/migrations.im.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
// server/modules/database/migrations.im.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';

test('runMigrations creates IM tables with expected columns', () => {
  const db = new Database(':memory:');
  runMigrations(db);

  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type='table'")
    .all()
    .map((r: any) => r.name);
  assert.ok(tables.includes('im_conversations'));
  assert.ok(tables.includes('im_messages'));
  assert.ok(tables.includes('im_read_cursors'));

  const msgCols = (db.prepare('PRAGMA table_info(im_messages)').all() as any[]).map((c) => c.name);
  for (const col of ['pk', 'conversation_id', 'source_id', 'seq', 'role', 'kind', 'content', 'tool_trace_count', 'raw_ref_start', 'raw_ref_end', 'created_at']) {
    assert.ok(msgCols.includes(col), `missing column ${col}`);
  }
  db.close();
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/modules/database/migrations.im.test.ts`
Expected: FAIL — `im_conversations` 不在 tables 中。

- [ ] **Step 3: 在 schema.ts 新增表 SQL**

在 `server/modules/database/schema.ts` 的 `INIT_SCHEMA_SQL` 常量定义之前追加：

```ts
export const IM_CONVERSATIONS_TABLE_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS im_conversations (
    id TEXT PRIMARY KEY NOT NULL,
    contact_id TEXT,
    provider_id TEXT NOT NULL DEFAULT 'claude',
    title TEXT,
    last_message_preview TEXT,
    last_seq INTEGER NOT NULL DEFAULT 0,
    last_activity_at INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    is_muted INTEGER NOT NULL DEFAULT 0
);
`;

export const IM_MESSAGES_TABLE_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS im_messages (
    pk INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    role TEXT NOT NULL,
    kind TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    tool_trace_count INTEGER NOT NULL DEFAULT 0,
    raw_ref_start TEXT,
    raw_ref_end TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    UNIQUE (conversation_id, source_id)
);
`;

export const IM_READ_CURSORS_TABLE_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS im_read_cursors (
    conversation_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    last_read_seq INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (conversation_id, device_id)
);
`;
```

- [ ] **Step 4: 在 migrations.ts 创建 IM 表**

先在 `migrations.ts` 顶部 import 块（`@/modules/database/schema.js` 的现有 import）追加这三个常量：

```ts
import {
  APP_CONFIG_TABLE_SCHEMA_SQL,
  IM_CONVERSATIONS_TABLE_SCHEMA_SQL,
  IM_MESSAGES_TABLE_SCHEMA_SQL,
  IM_READ_CURSORS_TABLE_SCHEMA_SQL,
  LAST_SCANNED_AT_SQL,
  PROJECTS_TABLE_SCHEMA_SQL,
  PUSH_SUBSCRIPTIONS_TABLE_SCHEMA_SQL,
  SESSIONS_TABLE_SCHEMA_SQL,
  USER_NOTIFICATION_PREFERENCES_TABLE_SCHEMA_SQL,
  VAPID_KEYS_TABLE_SCHEMA_SQL,
} from '@/modules/database/schema.js';
```

然后在 `runMigrations` 里 `db.exec(LAST_SCANNED_AT_SQL);`（migrations.ts:452）之后、`console.log('Database migrations completed successfully');` 之前插入：

```ts
    db.exec(IM_CONVERSATIONS_TABLE_SCHEMA_SQL);
    db.exec(IM_MESSAGES_TABLE_SCHEMA_SQL);
    db.exec(IM_READ_CURSORS_TABLE_SCHEMA_SQL);
    db.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_im_messages_conv_seq ON im_messages(conversation_id, seq)');
    db.exec('CREATE INDEX IF NOT EXISTS idx_im_conversations_activity ON im_conversations(last_activity_at)');
```

- [ ] **Step 5: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/modules/database/migrations.im.test.ts`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add server/modules/database/schema.ts server/modules/database/migrations.ts server/modules/database/migrations.im.test.ts
git commit -m "feat(im): add IM state tables (conversations/messages/read cursors)"
```

---

## Task 2: 蒸馏纯函数 `distillJsonl`

**Files:**
- Create: `server/services/im-distill.service.ts`
- Test: `server/services/im-distill.service.test.ts`

**蒸馏规则（spec §6）：** 用户文本→`text`；assistant 文本→`result`（同一轮累积）；`tool_use` 块→计入 `toolTrace.count`（count = tool_use operations only）；tool_result-only 的 user 条目→仅扩展 rawRef 区间，不增加 count；`thinking`→丢弃；`isError`→`error`。一轮以"下一条真实用户文本"或文件结束为边界 flush。

- [ ] **Step 1: 写失败测试**

```ts
// server/services/im-distill.service.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { distillJsonl, type RawJsonlEntry } from '@/services/im-distill.service.js';

test('keeps user text and assistant final result, drops tools/thinking', () => {
  const entries: RawJsonlEntry[] = [
    { type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: '帮我重构 a.ts' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'thinking', thinking: '...' }, { type: 'tool_use', id: 't1', name: 'Edit' }] } },
    { type: 'user', uuid: 'tr1', timestamp: '2026-05-29T00:00:02.000Z', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } },
    { type: 'assistant', uuid: 'a2', timestamp: '2026-05-29T00:00:03.000Z', message: { role: 'assistant', content: [{ type: 'text', text: '重构完成。' }] } },
  ];

  const out = distillJsonl(entries);

  assert.equal(out.length, 2);
  assert.equal(out[0].role, 'user');
  assert.equal(out[0].kind, 'text');
  assert.equal(out[0].content, '帮我重构 a.ts');

  assert.equal(out[1].role, 'assistant');
  assert.equal(out[1].kind, 'result');
  assert.equal(out[1].content, '重构完成。');
  assert.deepEqual(out[1].toolTrace, { count: 1, rawRefStart: 'a1', rawRefEnd: 'tr1' });
  assert.equal(out[1].sourceId, 'a2');
});

test('error entry becomes an error message', () => {
  const entries: RawJsonlEntry[] = [
    { type: 'assistant', uuid: 'e1', timestamp: '2026-05-29T00:00:00.000Z', isError: true, message: { role: 'assistant', content: [{ type: 'text', text: 'API error 500' }] } },
  ];
  const out = distillJsonl(entries);
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, 'error');
  assert.equal(out[0].content, 'API error 500');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-distill.service.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现 `distillJsonl`**

```ts
// server/services/im-distill.service.ts

export interface RawJsonlEntry {
  type: string;
  message?: { role?: string; content?: unknown };
  uuid?: string;
  timestamp?: string;
  isError?: boolean;
}

export type DistilledKind = 'text' | 'result' | 'question' | 'plan' | 'error';

export interface DistilledMessage {
  sourceId: string;
  role: 'user' | 'assistant' | 'system';
  kind: DistilledKind;
  content: string;
  createdAt: number;
  toolTrace?: { count: number; rawRefStart: string; rawRefEnd: string };
}

interface Block { type?: string; text?: string; name?: string }

function toBlocks(content: unknown): Block[] {
  if (Array.isArray(content)) return content as Block[];
  return [];
}

function userText(content: unknown): string | null {
  if (typeof content === 'string') return content.trim() || null;
  const blocks = toBlocks(content);
  // tool_result-only messages are NOT user text
  const hasToolResult = blocks.some((b) => b.type === 'tool_result');
  const text = blocks.filter((b) => b.type === 'text' && typeof b.text === 'string').map((b) => b.text).join('');
  if (text.trim()) return text.trim();
  return hasToolResult ? null : null;
}

function isToolResultOnly(content: unknown): boolean {
  const blocks = toBlocks(content);
  return blocks.length > 0 && blocks.every((b) => b.type === 'tool_result');
}

function ts(entry: RawJsonlEntry): number {
  const t = entry.timestamp ? Date.parse(entry.timestamp) : NaN;
  return Number.isFinite(t) ? t : 0;
}

/**
 * Distill raw Claude Code jsonl entries into a clean IM message stream.
 * Pure & deterministic — no IO, safe to unit test.
 */
export function distillJsonl(entries: RawJsonlEntry[]): DistilledMessage[] {
  const out: DistilledMessage[] = [];

  // In-progress assistant turn accumulator.
  let accText = '';
  let toolCount = 0;
  let rawStart: string | null = null;
  let rawEnd: string | null = null;
  let lastAssistantId: string | null = null;
  let lastAssistantTs = 0;
  let turnIsError = false;

  const flushAssistant = () => {
    if (lastAssistantId === null && toolCount === 0) return;
    if (!accText.trim() && toolCount === 0) return;
    const sourceId = lastAssistantId ?? rawStart ?? `turn-${out.length}`;
    const msg: DistilledMessage = {
      sourceId,
      role: 'assistant',
      kind: turnIsError ? 'error' : 'result',
      content: accText.trim(),
      createdAt: lastAssistantTs,
    };
    if (toolCount > 0 && rawStart && rawEnd) {
      msg.toolTrace = { count: toolCount, rawRefStart: rawStart, rawRefEnd: rawEnd };
    }
    out.push(msg);
    accText = '';
    toolCount = 0;
    rawStart = null;
    rawEnd = null;
    lastAssistantId = null;
    lastAssistantTs = 0;
    turnIsError = false;
  };

  const noteRaw = (id?: string) => {
    if (!id) return;
    if (rawStart === null) rawStart = id;
    rawEnd = id;
  };

  for (const entry of entries) {
    if (entry.type === 'user') {
      if (isToolResultOnly(entry.message?.content)) {
        noteRaw(entry.uuid);
        continue;
      }
      const text = userText(entry.message?.content);
      if (text) {
        flushAssistant();
        out.push({
          sourceId: entry.uuid ?? `user-${out.length}`,
          role: 'user',
          kind: 'text',
          content: text,
          createdAt: ts(entry),
        });
      }
      continue;
    }

    if (entry.type === 'assistant') {
      const blocks = toBlocks(entry.message?.content);
      if (typeof entry.message?.content === 'string') {
        accText += entry.message.content;
      }
      for (const b of blocks) {
        if (b.type === 'text' && typeof b.text === 'string') accText += b.text;
        else if (b.type === 'tool_use') { toolCount += 1; }
        // thinking ignored
      }
      noteRaw(entry.uuid);
      lastAssistantId = entry.uuid ?? lastAssistantId;
      lastAssistantTs = ts(entry);
      if (entry.isError) turnIsError = true;
      continue;
    }
    // other types (system / ai-title / summary) are ignored in the IM stream
  }

  flushAssistant();
  return out;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-distill.service.test.ts`
Expected: PASS（两个用例均过）

- [ ] **Step 5: 提交**

```bash
git add server/services/im-distill.service.ts server/services/im-distill.service.test.ts
git commit -m "feat(im): pure jsonl distillation into clean IM message stream"
```

---

## Task 3: IM 仓库 `imDb`

**Files:**
- Create: `server/modules/database/repositories/im.db.ts`
- Modify: `server/modules/database/index.ts`
- Test: `server/modules/database/repositories/im.db.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
// server/modules/database/repositories/im.db.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';

function freshDb() {
  const db = new Database(':memory:');
  runMigrations(db);
  __setConnectionForTests(db);
  return db;
}

test('insertMessages assigns monotonic per-conversation seq and is idempotent', () => {
  freshDb();
  imDb.ensureConversation('c1', 'proj1', 'Conv 1');

  const first = imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
    { sourceId: 's2', role: 'assistant', kind: 'result', content: 'hello', createdAt: 2 },
  ]);
  assert.equal(first, 2);
  assert.equal(imDb.getMaxSeq('c1'), 2);

  // Re-ingesting the same sourceIds inserts nothing new and keeps seq stable.
  const second = imDb.insertMessages('c1', [
    { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
    { sourceId: 's3', role: 'assistant', kind: 'result', content: 'again', createdAt: 3 },
  ]);
  assert.equal(second, 1);
  assert.equal(imDb.getMaxSeq('c1'), 3);

  const msgs = imDb.listMessages('c1', { numBefore: 0, numAfter: 100 });
  assert.deepEqual(msgs.map((m) => m.seq), [1, 2, 3]);
  assert.deepEqual(msgs.map((m) => m.source_id), ['s1', 's2', 's3']);
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
```

- [ ] **Step 2: 给 connection.ts 加测试注入钩子（若不存在）**

先确认 `server/modules/database/connection.ts` 是否导出测试钩子。打开文件查看 `getConnection`。若没有 `__setConnectionForTests`，追加：

```ts
// server/modules/database/connection.ts —— 在文件末尾追加
let testConnectionOverride: import('better-sqlite3').Database | null = null;

/** Test-only: inject an in-memory DB so repositories operate on it. */
export const __setConnectionForTests = (db: import('better-sqlite3').Database | null): void => {
  testConnectionOverride = db;
};
```

并在 `getConnection()` 函数体最前面加入：

```ts
  if (testConnectionOverride) return testConnectionOverride;
```

（若 `getConnection` 用的是模块级缓存变量，保持原逻辑，仅在最前面插入上面这行短路。）

- [ ] **Step 3: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/modules/database/repositories/im.db.test.ts`
Expected: FAIL — `imDb` 模块不存在。

- [ ] **Step 4: 实现仓库**

```ts
// server/modules/database/repositories/im.db.ts
import { getConnection } from '@/modules/database/connection.js';
import type { DistilledMessage } from '@/services/im-distill.service.js';

export interface ImMessageRow {
  pk: number;
  conversation_id: string;
  source_id: string;
  seq: number;
  role: string;
  kind: string;
  content: string;
  tool_trace_count: number;
  raw_ref_start: string | null;
  raw_ref_end: string | null;
  created_at: number;
}

export interface ImConversationRow {
  id: string;
  contact_id: string | null;
  provider_id: string;
  title: string | null;
  last_message_preview: string | null;
  last_seq: number;
  last_activity_at: number;
  is_pinned: number;
  is_muted: number;
}

export interface ImReadCursorRow {
  conversation_id: string;
  device_id: string;
  last_read_seq: number;
  updated_at: number;
}

export const imDb = {
  ensureConversation(id: string, contactId: string | null, title: string | null): void {
    const db = getConnection();
    db.prepare(
      `INSERT INTO im_conversations (id, contact_id, title)
       VALUES (?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         contact_id = COALESCE(excluded.contact_id, im_conversations.contact_id),
         title = COALESCE(excluded.title, im_conversations.title)`
    ).run(id, contactId, title);
  },

  getMaxSeq(conversationId: string): number {
    const db = getConnection();
    const row = db
      .prepare('SELECT COALESCE(MAX(seq), 0) AS max_seq FROM im_messages WHERE conversation_id = ?')
      .get(conversationId) as { max_seq: number };
    return row.max_seq;
  },

  /** Idempotently insert distilled messages, assigning monotonic seq.
   *  Returns the number of NEW rows inserted. */
  insertMessages(conversationId: string, messages: DistilledMessage[]): number {
    const db = getConnection();
    let seq = imDb.getMaxSeq(conversationId);
    let inserted = 0;
    let lastPreview = '';
    let lastActivity = 0;

    const insert = db.prepare(
      `INSERT OR IGNORE INTO im_messages
        (conversation_id, source_id, seq, role, kind, content, tool_trace_count, raw_ref_start, raw_ref_end, created_at)
       VALUES (@conversation_id, @source_id, @seq, @role, @kind, @content, @tool_trace_count, @raw_ref_start, @raw_ref_end, @created_at)`
    );

    const tx = db.transaction((rows: DistilledMessage[]) => {
      for (const m of rows) {
        const nextSeq = seq + 1;
        const res = insert.run({
          conversation_id: conversationId,
          source_id: m.sourceId,
          seq: nextSeq,
          role: m.role,
          kind: m.kind,
          content: m.content,
          tool_trace_count: m.toolTrace?.count ?? 0,
          raw_ref_start: m.toolTrace?.rawRefStart ?? null,
          raw_ref_end: m.toolTrace?.rawRefEnd ?? null,
          created_at: m.createdAt,
        });
        if (res.changes > 0) {
          seq = nextSeq;
          inserted += 1;
          lastPreview = m.content.slice(0, 120);
          lastActivity = m.createdAt;
        }
      }
    });
    tx(messages);

    if (inserted > 0) {
      db.prepare(
        `UPDATE im_conversations
           SET last_seq = ?, last_message_preview = ?, last_activity_at = ?
         WHERE id = ?`
      ).run(seq, lastPreview, lastActivity, conversationId);
    }
    return inserted;
  },

  listMessages(
    conversationId: string,
    opts: { anchorSeq?: number; numBefore: number; numAfter: number }
  ): ImMessageRow[] {
    const db = getConnection();
    const anchor = opts.anchorSeq ?? Number.MAX_SAFE_INTEGER;
    const before = db
      .prepare(
        `SELECT * FROM im_messages WHERE conversation_id = ? AND seq < ?
         ORDER BY seq DESC LIMIT ?`
      )
      .all(conversationId, anchor, opts.numBefore) as ImMessageRow[];
    const after = db
      .prepare(
        `SELECT * FROM im_messages WHERE conversation_id = ? AND seq >= ?
         ORDER BY seq ASC LIMIT ?`
      )
      .all(conversationId, anchor === Number.MAX_SAFE_INTEGER ? 0 : anchor, opts.numAfter) as ImMessageRow[];
    return [...before.reverse(), ...after];
  },

  listConversations(): ImConversationRow[] {
    const db = getConnection();
    return db
      .prepare('SELECT * FROM im_conversations ORDER BY is_pinned DESC, last_activity_at DESC')
      .all() as ImConversationRow[];
  },

  setConversationState(id: string, state: { isPinned?: boolean; isMuted?: boolean }): void {
    const db = getConnection();
    if (state.isPinned !== undefined) {
      db.prepare('UPDATE im_conversations SET is_pinned = ? WHERE id = ?').run(state.isPinned ? 1 : 0, id);
    }
    if (state.isMuted !== undefined) {
      db.prepare('UPDATE im_conversations SET is_muted = ? WHERE id = ?').run(state.isMuted ? 1 : 0, id);
    }
  },

  setReadCursor(conversationId: string, deviceId: string, lastReadSeq: number): void {
    const db = getConnection();
    db.prepare(
      `INSERT INTO im_read_cursors (conversation_id, device_id, last_read_seq, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(conversation_id, device_id) DO UPDATE SET
         last_read_seq = MAX(im_read_cursors.last_read_seq, excluded.last_read_seq),
         updated_at = excluded.updated_at`
    ).run(conversationId, deviceId, lastReadSeq, Date.now());
  },

  getReadCursors(): ImReadCursorRow[] {
    const db = getConnection();
    return db.prepare('SELECT * FROM im_read_cursors').all() as ImReadCursorRow[];
  },

  /** Global incremental sync: messages with pk > cursor. Returns rows + new cursor. */
  getMessagesSince(cursor: number, limit: number): { rows: ImMessageRow[]; cursor: number; hasMore: boolean } {
    const db = getConnection();
    const rows = db
      .prepare('SELECT * FROM im_messages WHERE pk > ? ORDER BY pk ASC LIMIT ?')
      .all(cursor, limit + 1) as ImMessageRow[];
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const newCursor = page.length > 0 ? page[page.length - 1].pk : cursor;
    return { rows: page, cursor: newCursor, hasMore };
  },
};
```

> **注意 `Date.now()`**：仓库运行在真实服务进程中，可正常使用；测试用例不对 `updated_at` 的具体值断言。

- [ ] **Step 5: barrel 导出**

在 `server/modules/database/index.ts` 按字母序插入：

```ts
export { imDb } from '@/modules/database/repositories/im.db.js';
```

- [ ] **Step 6: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/modules/database/repositories/im.db.test.ts`
Expected: PASS

- [ ] **Step 7: 提交**

```bash
git add server/modules/database/repositories/im.db.ts server/modules/database/repositories/im.db.test.ts server/modules/database/index.ts server/modules/database/connection.ts
git commit -m "feat(im): imDb repository with monotonic seq + global sync cursor"
```

---

## Task 4: 落库服务 `im-ingest`（读 jsonl → 蒸馏 → imDb）

**Files:**
- Create: `server/services/im-ingest.service.ts`
- Test: `server/services/im-ingest.service.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
// server/services/im-ingest.service.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';
import { ingestSessionJsonl } from '@/services/im-ingest.service.js';

test('ingestSessionJsonl distills a jsonl file into imDb messages', async () => {
  const db = new Database(':memory:');
  runMigrations(db);
  __setConnectionForTests(db);

  const dir = mkdtempSync(join(tmpdir(), 'im-ingest-'));
  const file = join(dir, 'sess1.jsonl');
  const lines = [
    JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', cwd: '/repo', message: { role: 'user', content: 'hello' } }),
    JSON.stringify({ type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'hi there' }] } }),
  ].join('\n');
  writeFileSync(file, lines, 'utf8');

  const inserted = await ingestSessionJsonl({ sessionId: 'sess1', contactId: '/repo', title: 'hello', jsonlPath: file });
  assert.equal(inserted, 2);

  const msgs = imDb.listMessages('sess1', { numBefore: 0, numAfter: 100 });
  assert.deepEqual(msgs.map((m) => m.content), ['hello', 'hi there']);

  // Idempotent re-ingest inserts nothing new.
  const again = await ingestSessionJsonl({ sessionId: 'sess1', contactId: '/repo', title: 'hello', jsonlPath: file });
  assert.equal(again, 0);
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-ingest.service.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现**

```ts
// server/services/im-ingest.service.ts
import { createReadStream } from 'node:fs';
import readline from 'node:readline';

import { imDb } from '@/modules/database/index.js';
import { distillJsonl, type RawJsonlEntry } from '@/services/im-distill.service.js';

export interface IngestOptions {
  sessionId: string;
  contactId: string | null;
  title: string | null;
  jsonlPath: string;
}

async function readEntries(jsonlPath: string): Promise<RawJsonlEntry[]> {
  const entries: RawJsonlEntry[] = [];
  const stream = createReadStream(jsonlPath, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line) as RawJsonlEntry);
    } catch {
      // skip malformed line
    }
  }
  rl.close();
  stream.destroy();
  return entries;
}

/** Read a session jsonl, distill it, and idempotently persist to imDb.
 *  Returns the number of newly inserted messages. */
export async function ingestSessionJsonl(opts: IngestOptions): Promise<number> {
  imDb.ensureConversation(opts.sessionId, opts.contactId, opts.title);
  const entries = await readEntries(opts.jsonlPath);
  const distilled = distillJsonl(entries);
  return imDb.insertMessages(opts.sessionId, distilled);
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-ingest.service.test.ts`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add server/services/im-ingest.service.ts server/services/im-ingest.service.test.ts
git commit -m "feat(im): ingest service reads session jsonl into distilled imDb messages"
```

---

## Task 5: WS 事件构造器 `im-events`

**Files:**
- Create: `server/services/im-events.service.ts`
- Test: `server/services/im-events.service.test.ts`

构造器与广播分离：纯函数 `buildImMessageEvent` 等可单测；`broadcastImEvent` 复用现有 `connectedClients` 广播模式（见 `projects-with-sessions-fetch.service.ts:181-192`）。

- [ ] **Step 1: 写失败测试**

```ts
// server/services/im-events.service.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildImMessageEvent, buildImReadEvent } from '@/services/im-events.service.js';

test('buildImMessageEvent shapes the wire frame', () => {
  const frame = buildImMessageEvent({
    pk: 10, conversation_id: 'c1', source_id: 's2', seq: 2,
    role: 'assistant', kind: 'result', content: 'done',
    tool_trace_count: 3, raw_ref_start: 'a1', raw_ref_end: 'tr1', created_at: 5,
  });
  assert.equal(frame.type, 'im:message');
  assert.equal(frame.message.id, 's2');
  assert.equal(frame.message.conversationId, 'c1');
  assert.equal(frame.message.seq, 2);
  assert.equal(frame.message.kind, 'result');
  assert.deepEqual(frame.message.toolTrace, { count: 3, rawRefStart: 'a1', rawRefEnd: 'tr1' });
});

test('buildImReadEvent shapes the read frame', () => {
  const frame = buildImReadEvent('c1', 'deviceA', 7);
  assert.equal(frame.type, 'im:read');
  assert.equal(frame.conversationId, 'c1');
  assert.equal(frame.deviceId, 'deviceA');
  assert.equal(frame.lastReadSeq, 7);
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-events.service.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现**

```ts
// server/services/im-events.service.ts
import { WS_OPEN_STATE, connectedClients } from '@/modules/websocket/index.js';
import type { RealtimeClientConnection } from '@/shared/types.js';
import type { ImMessageRow } from '@/modules/database/repositories/im.db.js';

export function serializeMessage(row: ImMessageRow) {
  const base = {
    id: row.source_id,
    conversationId: row.conversation_id,
    seq: row.seq,
    role: row.role,
    kind: row.kind,
    content: row.content,
    createdAt: row.created_at,
  };
  if (row.tool_trace_count > 0 && row.raw_ref_start && row.raw_ref_end) {
    return {
      ...base,
      toolTrace: { count: row.tool_trace_count, rawRefStart: row.raw_ref_start, rawRefEnd: row.raw_ref_end },
    };
  }
  return base;
}

export function buildImMessageEvent(row: ImMessageRow) {
  return { type: 'im:message' as const, message: serializeMessage(row) };
}

export function buildImReadEvent(conversationId: string, deviceId: string, lastReadSeq: number) {
  return { type: 'im:read' as const, conversationId, deviceId, lastReadSeq };
}

export function buildImPokeEvent(since: number) {
  return { type: 'im:poke' as const, since };
}

/** Broadcast an IM event frame to every open chat WS client. */
export function broadcastImEvent(frame: unknown): void {
  const payload = JSON.stringify(frame);
  connectedClients.forEach((client: RealtimeClientConnection) => {
    if (client.readyState === WS_OPEN_STATE) {
      client.send(payload);
    }
  });
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-events.service.test.ts`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add server/services/im-events.service.ts server/services/im-events.service.test.ts
git commit -m "feat(im): WS event builders + connectedClients broadcast"
```

---

## Task 6: 同步 REST 路由 `/api/im`

**Files:**
- Create: `server/routes/im.js`
- Modify: `server/index.js`（import + `app.use`）
- Test: `server/routes/im.test.ts`

端点（spec §8.1）：`GET /sync`、`GET /conversations/:id/messages`、`POST /conversations/:id/read`、`POST /conversations/:id/state`、`GET /conversations`。`send` 与 `transcript/blob` 见 Task 7/8。

- [ ] **Step 1: 写失败测试（用 express app 直挂路由 + supertest 风格的内置 fetch）**

```ts
// server/routes/im.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import Database from 'better-sqlite3';

import { runMigrations } from '@/modules/database/migrations.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { imDb } from '@/modules/database/repositories/im.db.js';
import imRoutes from '@/routes/im.js';

async function startServer() {
  const db = new Database(':memory:');
  runMigrations(db);
  __setConnectionForTests(db);
  const app = express();
  app.use(express.json());
  app.use('/api/im', imRoutes);
  const server = app.listen(0);
  const port = (server.address() as any).port;
  return { server, base: `http://127.0.0.1:${port}/api/im` };
}

test('GET /sync returns messages since cursor and read endpoint updates cursor', async () => {
  const { server, base } = await startServer();
  try {
    imDb.ensureConversation('c1', '/repo', 'Conv 1');
    imDb.insertMessages('c1', [
      { sourceId: 's1', role: 'user', kind: 'text', content: 'hi', createdAt: 1 },
      { sourceId: 's2', role: 'assistant', kind: 'result', content: 'yo', createdAt: 2 },
    ]);

    const sync = await (await fetch(`${base}/sync?since=0`)).json();
    assert.equal(sync.messages.length, 2);
    assert.equal(sync.messages[0].id, 's1');
    assert.ok(sync.cursor >= 2);
    assert.equal(sync.conversations.length, 1);

    const readRes = await fetch(`${base}/conversations/c1/read`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: 'devA', lastReadSeq: 2 }),
    });
    assert.equal(readRes.status, 200);
    assert.equal(imDb.getReadCursors().find((c) => c.device_id === 'devA')?.last_read_seq, 2);
  } finally {
    server.close();
  }
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/routes/im.test.ts`
Expected: FAIL — `@/routes/im.js` 不存在。

- [ ] **Step 3: 实现路由**

```js
// server/routes/im.js
import express from 'express';

import { imDb } from '@/modules/database/index.js';
import { serializeMessage, buildImReadEvent, broadcastImEvent } from '@/services/im-events.service.js';

const router = express.Router();

const SYNC_PAGE = 200;

// GET /api/im/sync?since=<cursor> — incremental sync of messages + conversations + cursors.
router.get('/sync', (req, res) => {
  const since = Number.parseInt(String(req.query.since ?? '0'), 10) || 0;
  const { rows, cursor, hasMore } = imDb.getMessagesSince(since, SYNC_PAGE);
  res.json({
    messages: rows.map(serializeMessage),
    conversations: imDb.listConversations().map((c) => ({
      id: c.id,
      contactId: c.contact_id,
      providerId: c.provider_id,
      title: c.title,
      lastMessagePreview: c.last_message_preview,
      lastSeq: c.last_seq,
      lastActivityAt: c.last_activity_at,
      isPinned: !!c.is_pinned,
      isMuted: !!c.is_muted,
    })),
    readCursors: imDb.getReadCursors().map((r) => ({
      conversationId: r.conversation_id,
      deviceId: r.device_id,
      lastReadSeq: r.last_read_seq,
    })),
    cursor,
    hasMore,
  });
});

// GET /api/im/conversations — list only.
router.get('/conversations', (_req, res) => {
  res.json({ conversations: imDb.listConversations() });
});

// GET /api/im/conversations/:id/messages?anchor=&numBefore=&numAfter=
router.get('/conversations/:id/messages', (req, res) => {
  const anchor = req.query.anchor !== undefined ? Number.parseInt(String(req.query.anchor), 10) : undefined;
  const numBefore = Number.parseInt(String(req.query.numBefore ?? '40'), 10) || 40;
  const numAfter = Number.parseInt(String(req.query.numAfter ?? '0'), 10) || 0;
  const rows = imDb.listMessages(req.params.id, { anchorSeq: anchor, numBefore, numAfter });
  res.json({ messages: rows.map(serializeMessage) });
});

// POST /api/im/conversations/:id/read  { deviceId, lastReadSeq }
router.post('/conversations/:id/read', (req, res) => {
  const { deviceId, lastReadSeq } = req.body ?? {};
  if (typeof deviceId !== 'string' || typeof lastReadSeq !== 'number') {
    return res.status(400).json({ error: 'deviceId (string) and lastReadSeq (number) required' });
  }
  imDb.setReadCursor(req.params.id, deviceId, lastReadSeq);
  broadcastImEvent(buildImReadEvent(req.params.id, deviceId, lastReadSeq));
  res.json({ ok: true });
});

// POST /api/im/conversations/:id/state  { isPinned?, isMuted? }
router.post('/conversations/:id/state', (req, res) => {
  const { isPinned, isMuted } = req.body ?? {};
  imDb.setConversationState(req.params.id, { isPinned, isMuted });
  res.json({ ok: true });
});

export default router;
```

- [ ] **Step 4: 在 server/index.js 挂载**

在 index.js 路由 import 区（约 :36-44 的 `import ... from './routes/...'` 之后）加：

```js
import imRoutes from './routes/im.js';
```

在 `app.use('/api/providers', authenticateToken, providerRoutes);`（约 :151）之后加：

```js
app.use('/api/im', authenticateToken, imRoutes);
```

- [ ] **Step 5: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/routes/im.test.ts`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add server/routes/im.js server/index.js server/routes/im.test.ts
git commit -m "feat(im): sync REST routes (sync/messages/read/state) mounted at /api/im"
```

---

## Task 7: 完整记录（原始 transcript）分页路由

**Files:**
- Modify: `server/routes/im.js`（新增 transcript + blob 端点）
- Create: `server/services/im-transcript.service.ts`
- Test: `server/services/im-transcript.service.test.ts`

原始 transcript 不进 IM 库，按 spec §10 分页 + 大 blob 引用化：transcript 页只返回每条的摘要 + entryId；`/blob/:entryId` 返回完整 payload。

- [ ] **Step 1: 写失败测试**

```ts
// server/services/im-transcript.service.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { readTranscriptPage } from '@/services/im-transcript.service.js';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'im-tr-'));
  const file = join(dir, 's.jsonl');
  const lines = [
    JSON.stringify({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'do x' } }),
    JSON.stringify({ type: 'assistant', uuid: 'a1', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Edit', input: { file: 'a.ts' } }] } }),
    JSON.stringify({ type: 'assistant', uuid: 'a2', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } }),
  ].join('\n');
  writeFileSync(file, lines, 'utf8');
  return file;
}

test('readTranscriptPage paginates raw entries with summaries', async () => {
  const file = fixture();
  const page = await readTranscriptPage({ jsonlPath: file, anchor: undefined, numBefore: 0, numAfter: 2 });
  assert.equal(page.entries.length, 2);
  assert.equal(page.entries[0].id, 'u1');
  assert.equal(page.entries[0].type, 'user');
  assert.ok(typeof page.entries[0].summary === 'string');
  assert.equal(page.hasMoreAfter, true);
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-transcript.service.test.ts`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现 transcript 服务**

```ts
// server/services/im-transcript.service.ts
import { createReadStream } from 'node:fs';
import readline from 'node:readline';

export interface TranscriptEntrySummary {
  id: string;
  type: string;
  summary: string;     // 短摘要；大 blob 需 /blob/:id 单取
  hasBlob: boolean;
}

export interface TranscriptPage {
  entries: TranscriptEntrySummary[];
  hasMoreBefore: boolean;
  hasMoreAfter: boolean;
}

const BLOB_THRESHOLD = 2000; // chars

function summarize(obj: any): { summary: string; hasBlob: boolean } {
  const content = obj?.message?.content;
  let text = '';
  if (typeof content === 'string') text = content;
  else if (Array.isArray(content)) {
    text = content
      .map((b: any) => b?.text ?? b?.name ?? b?.type ?? '')
      .join(' ');
  }
  const hasBlob = text.length > BLOB_THRESHOLD;
  return { summary: hasBlob ? `${text.slice(0, 200)}…` : text, hasBlob };
}

async function readAll(jsonlPath: string): Promise<any[]> {
  const out: any[] = [];
  const stream = createReadStream(jsonlPath, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch { /* skip */ }
  }
  rl.close();
  stream.destroy();
  return out;
}

/** Cursor-paginated raw transcript (Zulip-style anchor + numBefore/numAfter). */
export async function readTranscriptPage(opts: {
  jsonlPath: string;
  anchor?: string;            // entry id
  numBefore: number;
  numAfter: number;
}): Promise<TranscriptPage> {
  const all = await readAll(opts.jsonlPath);
  const withIds = all.map((o, i) => ({ obj: o, id: o.uuid ?? `idx-${i}`, idx: i }));
  let anchorIdx = withIds.length; // default: end (so numBefore walks back)
  if (opts.anchor) {
    const found = withIds.find((e) => e.id === opts.anchor);
    if (found) anchorIdx = found.idx;
  }
  const startIdx = Math.max(0, anchorIdx - opts.numBefore);
  const endIdx = Math.min(withIds.length, anchorIdx + opts.numAfter);
  const slice = withIds.slice(startIdx, endIdx);
  const entries = slice.map((e) => {
    const s = summarize(e.obj);
    return { id: e.id, type: e.obj?.type ?? 'unknown', summary: s.summary, hasBlob: s.hasBlob };
  });
  return {
    entries,
    hasMoreBefore: startIdx > 0,
    hasMoreAfter: endIdx < withIds.length,
  };
}

/** Returns the full raw payload for a single entry id (lazy blob fetch). */
export async function readTranscriptBlob(jsonlPath: string, entryId: string): Promise<any | null> {
  const all = await readAll(jsonlPath);
  const found = all.find((o, i) => (o.uuid ?? `idx-${i}`) === entryId);
  return found ?? null;
}
```

- [ ] **Step 4: 路由接入**

在 `server/routes/im.js` 顶部 import 追加：

```js
import { sessionsDb } from '@/modules/database/index.js';
import { readTranscriptPage, readTranscriptBlob } from '@/services/im-transcript.service.js';
```

在 `export default router;` 之前追加端点（用 `sessionsDb` 把 conversationId=session_id 解析出 jsonl_path）：

```js
function jsonlPathForConversation(conversationId) {
  const row = sessionsDb.getSessionById?.(conversationId);
  return row?.jsonl_path ?? null;
}

// GET /api/im/conversations/:id/transcript?anchor=&numBefore=&numAfter=
router.get('/conversations/:id/transcript', async (req, res) => {
  const jsonlPath = jsonlPathForConversation(req.params.id);
  if (!jsonlPath) return res.status(404).json({ error: 'transcript not found' });
  const numBefore = Number.parseInt(String(req.query.numBefore ?? '40'), 10) || 40;
  const numAfter = Number.parseInt(String(req.query.numAfter ?? '0'), 10) || 0;
  const page = await readTranscriptPage({ jsonlPath, anchor: req.query.anchor, numBefore, numAfter });
  res.json(page);
});

// GET /api/im/conversations/:id/transcript/blob/:entryId
router.get('/conversations/:id/transcript/blob/:entryId', async (req, res) => {
  const jsonlPath = jsonlPathForConversation(req.params.id);
  if (!jsonlPath) return res.status(404).json({ error: 'transcript not found' });
  const blob = await readTranscriptBlob(jsonlPath, req.params.entryId);
  if (!blob) return res.status(404).json({ error: 'entry not found' });
  res.json({ entry: blob });
});
```

> **校验 `sessionsDb` 方法名**：实现前打开 `server/modules/database/repositories/sessions.db.ts` 确认按 session_id 取 jsonl_path 的方法实际名称；若不是 `getSessionById`，替换为真实方法（如 `getById`/`findBySessionId`）。本步骤的可选链 `?.` 仅为防御，最终应使用确切方法名并去掉可选链。

- [ ] **Step 5: 运行 service 测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-transcript.service.test.ts`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add server/services/im-transcript.service.ts server/services/im-transcript.service.test.ts server/routes/im.js
git commit -m "feat(im): paginated raw transcript viewer with lazy blob fetch"
```

---

## Task 8: 接入实时流——会话完成后蒸馏 + 广播

**Files:**
- Modify: `server/services/im-ingest.service.ts`（新增 `ingestAndBroadcast`）
- Modify: 现有 session 写盘完成的钩子点（`server/modules/providers/services/sessions-watcher.service.ts` 或 `claude-sdk.js` 的 query 完成回调）
- Test: `server/services/im-ingest.service.test.ts`（新增广播用例）

让"AI 回复落盘"驱动蒸馏 + `im:message` 广播（→ 客户端红点/通知）。优先挂在**已存在的 jsonl watcher**（`sessions-watcher.service.ts` 已 import `connectedClients`），避免改 SDK 内核。

- [ ] **Step 1: 写失败测试（断言新插入的消息被广播）**

```ts
// 追加到 server/services/im-ingest.service.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import { runMigrations } from '@/modules/database/migrations.js';
import { __setConnectionForTests } from '@/modules/database/connection.js';
import { ingestAndBroadcast } from '@/services/im-ingest.service.js';

test('ingestAndBroadcast emits one frame per newly inserted message', async () => {
  const db = new Database(':memory:');
  runMigrations(db);
  __setConnectionForTests(db);

  const dir = mkdtempSync(join(tmpdir(), 'im-bc-'));
  const file = join(dir, 's.jsonl');
  writeFileSync(file, [
    JSON.stringify({ type: 'user', uuid: 'u1', timestamp: '2026-05-29T00:00:00.000Z', message: { role: 'user', content: 'q' } }),
    JSON.stringify({ type: 'assistant', uuid: 'a1', timestamp: '2026-05-29T00:00:01.000Z', message: { role: 'assistant', content: [{ type: 'text', text: 'a' }] } }),
  ].join('\n'), 'utf8');

  const frames: any[] = [];
  const inserted = await ingestAndBroadcast(
    { sessionId: 's', contactId: '/r', title: 'q', jsonlPath: file },
    (frame) => frames.push(frame)
  );
  assert.equal(inserted, 2);
  assert.equal(frames.length, 2);
  assert.equal(frames[1].type, 'im:message');
  assert.equal(frames[1].message.content, 'a');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-ingest.service.test.ts`
Expected: FAIL — `ingestAndBroadcast` 未导出。

- [ ] **Step 3: 实现 `ingestAndBroadcast`**

在 `server/services/im-ingest.service.ts` 追加（顶部 import 补 `imDb`、`buildImMessageEvent`、`broadcastImEvent`）：

```ts
import { buildImMessageEvent, broadcastImEvent } from '@/services/im-events.service.js';
import type { ImMessageRow } from '@/modules/database/repositories/im.db.js';

/** Ingest + emit an `im:message` frame for each newly inserted message.
 *  `emit` defaults to the real WS broadcast; tests inject a collector. */
export async function ingestAndBroadcast(
  opts: IngestOptions,
  emit: (frame: ReturnType<typeof buildImMessageEvent>) => void = broadcastImEvent
): Promise<number> {
  const before = imDb.getMaxSeq(opts.sessionId);
  const inserted = await ingestSessionJsonl(opts);
  if (inserted === 0) return 0;
  // New messages are those with seq > before.
  const fresh = imDb.listMessages(opts.sessionId, { anchorSeq: before + 1, numBefore: 0, numAfter: inserted });
  for (const row of fresh as ImMessageRow[]) {
    emit(buildImMessageEvent(row));
  }
  return inserted;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `npx tsx --tsconfig server/tsconfig.json --test server/services/im-ingest.service.test.ts`
Expected: PASS（含原有 2 个 + 新增 1 个）

- [ ] **Step 5: 挂到现有 watcher**

打开 `server/modules/providers/services/sessions-watcher.service.ts`，找到"某 session 的 jsonl 发生变化/写入"后已触发的回调点，在其后调用 `ingestAndBroadcast({ sessionId, contactId, title, jsonlPath })`（字段从 watcher 已有的 session 元数据取；jsonlPath 即被监听的文件路径）。仅新增一行调用，不改 watcher 原有逻辑。若 watcher 无现成元数据，用 `sessionsDb` 查 jsonl_path/contactId（= project_path）。

- [ ] **Step 6: 跑全量后端测试**

Run: `npx tsx --tsconfig server/tsconfig.json --test "server/**/*.test.ts"`
Expected: 全 PASS

- [ ] **Step 7: typecheck + lint**

Run: `npm run typecheck && npm run lint`
Expected: 通过（注意 boundaries 规则：跨模块经 barrel；`shared/types.ts` 只 `import type`）

- [ ] **Step 8: 提交**

```bash
git add server/services/im-ingest.service.ts server/services/im-ingest.service.test.ts server/modules/providers/services/sessions-watcher.service.ts
git commit -m "feat(im): broadcast im:message on session jsonl updates"
```

---

## Self-Review

**Spec coverage（对照 spec 章节）：**
- §6 两层存储 / 蒸馏规则 → Task 2（distill）+ Task 7（transcript 第二层）✅
- §7 数据模型（Contact/Conversation/Message/ReadCursor）→ Task 1（表）+ Task 3（仓库）✅
- §8.1 REST 端点：sync/messages/read/state → Task 6；transcript/blob → Task 7；send → **见下方说明**
- §8.2 WS 事件 im:message/im:read/im:poke → Task 5 + Task 8（im:conversation 由 sync 的 conversations 字段覆盖，未单独推送——已在 spec §8.2 标注 poke 兜底，可接受）
- §8.3 发送队列 → **客户端职责（子系统 2/5），服务端 `send` 端点说明见下**
- §9 服务端 hub（表/蒸馏/路由/WS/复用 VAPID）→ Task 1-8 ✅
- §10 transcript 分页 + blob 懒加载 → Task 7 ✅
- §11 未读/红点（lastSeq − readCursor、跨端清红点）→ Task 3 + Task 6（read 广播）✅

**`send` 端点说明（避免 placeholder）：** spec §8.1 的 `POST /send` = "启动/继续一次 Claude query"，其实现复用**现有 WS chat 路径**（`chat-websocket.service.ts` + `claude-sdk.js`），不在本计划新造——发送链路已存在，本计划只负责把其产出的 jsonl 蒸馏回 IM 流（Task 8）。故本计划不新增 `send` REST 端点，属有意决策，非遗漏。

**Placeholder scan：** 无 TBD/TODO；每个代码步骤均为完整可运行代码。Task 7 Step 4 与 Task 8 Step 5 标注了"实现前需对照真实方法名/钩子点"——这是对既有代码的接入校验，已给出确切定位文件与替换指引，非占位。

**Type consistency：** `DistilledMessage`（Task 2）字段贯穿 Task 3 `insertMessages` / Task 4 / Task 8；`ImMessageRow`（Task 3）贯穿 Task 5 `serializeMessage` / Task 8；`buildImMessageEvent` 返回类型在 Task 5 定义、Task 8 复用。一致。

---

## Known follow-ups (from final review — non-blocking)

- **Full-file re-read on every watcher event**: `ingestAndBroadcast` re-reads + re-distills the whole session jsonl on each `change` (watcher polls ~6s). Correct (UPSERT idempotent + stable per-turn id prevents duplicates) but O(file) per poll on long/active sessions. Future: per-session debounce and/or incremental distill from a stored byte offset.
- ~~Incremental sync of in-place content updates~~ — **RESOLVED**: `/sync` now uses a monotonic `rev` column bumped on insert AND in-place update, so a client re-receives streaming content edits even past its cursor (see `getMessagesSince`).

## Execution Handoff

完成于本会话(子代理驱动 + 后半段内联)。8 个任务全部实现并通过测试。
