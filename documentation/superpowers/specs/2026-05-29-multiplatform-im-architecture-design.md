# 多端统一 IM 架构 — 地基设计（子系统 0 + 1）

- **日期**: 2026-05-29
- **状态**: 待用户审阅
- **范围**: 本 spec 只覆盖 **子系统 0（IM 协议 + 数据模型契约）** 与 **子系统 1（服务端 IM hub 契约面）**。其余子系统（Swift core、iOS/macOS/Web/Windows 各端）在本文定稿后各自展开独立 spec。

---

## 1. 背景与目标

本仓库是 [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) 的 fork，已硬化为个人远程使用（TOTP + FRP 隧道，Mac 在家跑 `127.0.0.1:3001`）。

当前形态是"请求-响应式的 Claude Code 控制台"。本设计要把**整体架构按即时通讯（IM）App 重新设计**，覆盖 **macOS、iOS、Web，未来还有 Windows**，让每个端按同一套契约实现一致的、微信式的 IM 体验。

### 核心目标

1. **多端统一**：一套语言无关的协议 + 数据模型，所有端按同一契约实现。
2. **服务端为中心 hub**：服务端是权威真相，跨设备同步会话列表、消息、每设备已读位置（手机读了，桌面端红点也清）。
3. **本地优先**：客户端 SwiftData/IndexedDB 为本地真相缓存，离线可看历史、发送走持久化队列、乐观上屏。
4. **微信式 IM 体验**：会话列表（含未读小红点）+ 聊天详情（气泡）+ 通讯录 + 我；AI 回复后小红点 + 本地通知。
5. **零迁移风险**：不动 Claude Code 写 `~/.claude/projects/**/*.jsonl` 的机制——jsonl 仍是消息源真相。

### 概念映射

| IM 概念 | 本项目对应 |
|---|---|
| 一个聊天 / 会话（conversation） | 一个 Claude session |
| 联系人（contact） | 一个项目 / 工作目录（project） |
| 消息（message） | 蒸馏后的对话轮（用户输入 / Claude 最终回复） |
| "查看完整记录" | 该 session 的原始 jsonl transcript（含工具/思考） |

---

## 2. 范围分解与构建顺序

"多端统一 IM 架构 + 服务端 hub"跨多个相互依赖的子系统，无法用一个 spec 装下。分解如下，每个子系统单独走 spec → plan → 实现：

| # | 子系统 | 内容 | 依赖 | 本 spec |
|---|--------|------|------|---------|
| **0** | **IM 协议 + 数据模型契约** | 语言无关的会话/消息/投递态/已读游标定义 + 同步协议 | — | ✅ |
| **1** | **服务端 IM hub** | jsonl→蒸馏、IM 状态库、规范化同步 API、WS 推送 | 0 | ✅（契约面） |
| 2 | Swift IM core（ChatKit 重构） | 本地优先 SwiftData 库 + 同步客户端，macOS/iOS 共享 | 0,1 | 后续 |
| 3 | iOS app | 微信式 UI + 本地通知 + 小红点 | 2 | 后续 |
| 4 | macOS app | 接新 core/协议 | 2 | 后续 |
| 5 | Web 端 | 已有微信 UI，接新协议 | 1 | 后续 |
| 6 | Windows | Electron 复用 Web | 5 | 后续 |

**子系统 0 是地基，所有端都依赖它。** 构建顺序：0 → 1 → 2 → 3 → 4 → 5 → 6。

---

## 3. 已锁定的关键决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 聊天对象 | 每个 Claude session = 一个聊天 | 与现有数据模型一致 |
| 联系人 | = 项目 / 工作目录 | 自然的"会话归属" |
| 数据流 | 本地优先 + 后台同步 | IM 应用的本质 |
| 同步模型 | 服务端为中心 hub（微信式跨端同步） | 跨设备清红点、统一真相 |
| 服务端改动 | **在本设计范围内** | 需新增 IM 状态库 + 同步 API + WS 推送 |
| 消息存储 | 方案 C：jsonl 仍是源真相 + 叠加 IM 状态/同步层 | 零迁移风险，拿到 90% IM 体验 |
| 存储分层 | **两层**：蒸馏 IM 库（同步）+ 原始 transcript（按需、不同步） | 聊天流极轻、零卡顿 |
| 蒸馏规则 | 留：用户消息 / Claude 最终回复 / AskUserQuestion / 计划 / 报错；删：tool_use / tool_result / thinking | "正常聊天，只要结果" |
| 工具痕迹 | 聊天里留**灰色折叠小条**（"执行了 N 个操作·点开"），默认折叠 | 干净又不丢上下文 |
| 完整记录入口 | 联系人(项目)详情 → 各 session 完整 transcript；聊天右上角快捷跳转 | 用户指定 |
| 完整记录加载 | **分页 + 懒加载 + 大 blob 点开才拉** | 它才是含大 tool 输出的地方 |
| 通知 | 本地通知 + app badge（iOS）/ 现有 VAPID web push（Web） | 暂不引远程 APNs |
| Swift 端状态管理 | MVVM（ObservableObject），复用现有 ChatKit ViewModel | 改造量最小 |
| 交付范围 | 对齐网页版全功能，分阶段 | — |

---

## 4. 参考项目与依据

**主参考：野火 IM（WildFireChat）全栈方案**，并对照 Tinode / Zulip / Matrix / 本地优先同步引擎取长补短。**明确移除 WeChat-SwiftUI 作为参考。**

| 维度 | 主要参考 | 借鉴 | 避开 |
|---|---|---|---|
| 客户端分层 | [野火 ios-chat](https://github.com/wildfirechat/ios-chat) | 三层切分：`chatclient`(通讯核心) → `chatuikit`(UI 控件) → `chat`(app) | C++/Mars 核心（我们用 Swift core） |
| 服务端 hub 形态 | [野火 im-server](https://github.com/wildfirechat/im-server) + [Tinode](https://github.com/tinode/chat) | hub-and-spoke、多端全状态同步、IM 服务与业务/鉴权分离 | MQTT+Protobuf+Mars 重型栈（我们用 WS+JSON） |
| Web / PC / Windows | [野火 vue-chat](https://github.com/wildfirechat/vue-chat) / [vue-pc-chat](https://github.com/wildfirechat/vue-pc-chat) | Electron(Win/mac/Linux) 复用 Web 这条路 | **付费闭源 SDK（proto.min.js）**——我们走开放协议 |
| 未读/已读跨端同步 | [Zulip](https://zulip.readthedocs.io/en/latest/subsystems/unread_messages.html) | 服务端存每会话未读 id 集合；首连下发 `unread_msgs`；增量 flag 事件 | — |
| 历史分页 | [Zulip get-messages](https://zulip.com/api/get-messages) | `anchor + num_before/num_after` + `has_more` 元数据（用于完整记录查看器） | — |
| 客户端存储抽象 | [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk) | 存储 trait 抽象：原生 SQLite / Web IndexedDB，同步逻辑一致 | 单一 Rust core 统一所有端（改造太大） |
| 发送队列 / 增量拉取 | PowerSync / Replicache | 本地持久化上传队列 + 版本游标 pull + WS poke | 引入整个同步引擎 |

**我们独有的特化**（这些参考都没有）：针对 Claude Code 的**两层存储 + 服务端蒸馏**——把 jsonl 里的工具/思考剔出 IM 流，只留"正常聊天"。

---

## 5. 总体架构

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  iOS app    │   │  macOS app  │   │   Web (PWA) │   │ Windows     │
│ (ChatKit-UI)│   │ (ChatKit-UI)│   │ React 微信UI│   │ Electron←Web│
├─────────────┤   ├─────────────┤   ├─────────────┤   └─────────────┘
│ Swift core  │   │ Swift core  │   │  TS core    │
│ SwiftData   │   │ SwiftData   │   │  IndexedDB  │   ← 本地优先蒸馏镜像
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       └─────────────────┴─── JSON / WS ───┴────────────┐  ← 子系统 0 协议
                                                         ▼
                        ┌────────────────────────────────────────┐
                        │      Node 服务端 IM hub (子系统 1)        │
                        │  ┌──────────────┐  ┌──────────────────┐ │
                        │  │ 蒸馏服务      │  │ IM 状态库(SQLite) │ │
                        │  │ jsonl→消息    │  │ 会话/消息/已读游标 │ │
                        │  └──────┬───────┘  └──────────────────┘ │
                        │  ┌──────▼───────┐  ┌──────────────────┐ │
                        │  │ 同步 REST API │  │ WS 推送(poke/msg)│ │
                        │  └──────────────┘  └──────────────────┘ │
                        └───────────────┬──────────────────────────┘
                                        │ 读
                          ┌─────────────▼──────────────┐
                          │ ~/.claude/projects/**/*.jsonl│  ← 消息源真相（不动）
                          │  + claude-agent-sdk query()  │
                          └──────────────────────────────┘
```

**职责边界**：Claude SDK / jsonl 仍负责"和 Claude 对话 + 写原始记录"；IM hub 在其上做**蒸馏 + 状态 + 同步 + 推送**；客户端只认子系统 0 的协议，本地优先缓存蒸馏消息。

---

## 6. 两层存储模型

### 第一层：蒸馏 IM 库（同步、驱动聊天）

服务端从 jsonl 蒸馏出"正常聊天"流，只保留对话级内容。这一层：

- **极小**：一个长会话蒸馏后可能仅几十条 → 加载零卡顿。
- **跨端同步真相**：是客户端本地优先库（SwiftData / IndexedDB）存的内容。
- **未读 / 小红点 / 通知的数据源**：AI 回复结果落库即触发红点 + 本地通知。

### 第二层：完整原始记录（按需、不同步）

工具 / thinking / 中间过程留在 jsonl，**不进 IM 流、不进本地库、不污染聊天**。只有用户主动点"查看完整记录"才从服务端按需拉取，且**分页 + 懒加载 + 大 blob 点开才拉**。

### 蒸馏规则（服务端，单点执行，保证各端一致）

| jsonl 条目 | 蒸馏结果 |
|---|---|
| 用户输入 | ✅ `message{role:user, kind:text}` |
| assistant 最终文本回复 | ✅ `message{role:assistant, kind:result}` |
| AskUserQuestion | ✅ `message{kind:question}`（是对话） |
| ExitPlanMode / 计划 | ✅ `message{kind:plan}` |
| 错误 | ✅ `message{kind:error}` |
| tool_use / tool_result | ❌ 不单独成消息；折叠计入紧随其后 result 消息的 `toolTrace`（计数 + 原始条目范围引用） |
| thinking | ❌ 丢弃 |

`toolTrace` 用于聊天里的**灰色折叠小条**；其 `rawRefStart/rawRefEnd` 指向原始 jsonl 条目范围，点开即按需拉该轮工具详情。

---

## 7. IM 数据模型（语言无关契约）

字段用 camelCase，类型为协议层逻辑类型；各端映射到本地类型（SwiftData `@Model` / TS interface / SQLite 列）。

### Contact（= 项目）

```
Contact {
  id: string            // = projectId
  name: string          // displayName / 路径
  providerId: string    // "claude"
  conversationCount: int
}
```

### Conversation（= session）

```
Conversation {
  id: string                 // = session id
  contactId: string          // = projectId
  providerId: string
  title: string              // 显示名（summary/title 优先）
  lastMessagePreview: string // 最后一条蒸馏消息预览
  lastSeq: int               // 该会话当前最大 seq（同步/排序锚点）
  lastActivityAt: timestamp
  isPinned: bool             // 用户态，跨端同步
  isMuted: bool              // 用户态，跨端同步
  // 客户端派生（不在服务端存）：unreadCount = lastSeq - localReadSeq
}
```

### Message（蒸馏后的对话消息）

```
Message {
  id: string                 // 稳定 id，源自 jsonl 条目 uuid
  conversationId: string
  seq: int                   // 服务端分配的会话内单调序号 → 排序 & 游标 & 已读基准
  role: "user" | "assistant" | "system"
  kind: "text" | "result" | "question" | "plan" | "error"
  content: string            // 蒸馏文本（含 markdown / 代码块）
  createdAt: timestamp
  toolTrace?: {              // 灰色折叠小条；无工具则为空
    count: int               // "执行了 N 个操作"
    rawRefStart: string      // 原始 jsonl 条目区间起（懒加载详情用）
    rawRefEnd: string
  }
  // 客户端态（不在服务端存）：
  // deliveryState: "sending" | "sent" | "failed"
  // clientMsgId: string      // 乐观上屏对账用
}
```

### ReadCursor（每设备每会话已读位置）

```
ReadCursor {
  conversationId: string
  deviceId: string
  lastReadSeq: int
  updatedAt: timestamp
}
```

### 原始 transcript 条目（仅完整记录查看器用，不进 IM 库）

```
RawEntry {
  id: string                 // jsonl 条目 uuid
  conversationId: string
  type: string               // user/assistant/tool_use/tool_result/thinking/...
  payload: json              // 原始内容（大 blob 可单独按 id 拉）
  ts: timestamp
}
```

---

## 8. 同步协议（子系统 0 ↔ 1 契约）

传输：REST（HTTP）+ WebSocket（复用现有 `ws` 服务，新增 IM 消息类型）。鉴权沿用现有 JWT。

> **认证说明**：当前项目处于测试阶段，认证相关（TOTP / token 刷新 / WS 401）已被注释或跳过。本协议**预留** JWT 鉴权位，但本阶段实现不阻塞于认证流程。

### 8.1 REST 端点

| 端点 | 作用 | 关键参数 / 返回 |
|---|---|---|
| `GET /api/im/sync?since=<cursor>` | 初始 / 增量同步 | 返回 since 之后变更的会话 + 其新增蒸馏消息 + `unreadMsgs` 结构（Zulip 式：按会话分组的未读 seq 集合）+ 各会话 readCursor；返回新 `cursor` 与 `hasMore` |
| `GET /api/im/conversations/:id/messages?anchor=<seq>&numBefore=N&numAfter=M` | IM 聊天流向上翻页（蒸馏消息） | 返回消息页 + `hasMoreBefore/After` |
| `GET /api/im/conversations/:id/transcript?anchor=<entryId>&numBefore=N&numAfter=M` | **完整原始记录**分页（重，懒加载） | 返回 RawEntry 页 + `hasMore`；大 blob 仅返回引用 |
| `GET /api/im/transcript/blob/:entryId` | 按需拉单条大 blob（文件内容 / 大工具输出） | 完整 payload |
| `POST /api/im/conversations/:id/read` | 上报已读位置（跨端清红点） | body `{ lastReadSeq, deviceId }` |
| `POST /api/im/conversations/:id/state` | 置顶 / 免打扰 | body `{ isPinned?, isMuted? }` |
| `POST /api/im/conversations/:id/send` | 发送消息（= 启动/继续一次 Claude query） | body `{ clientMsgId, text }`；经现有 WS chat 路径驱动 Claude，蒸馏出的 user 消息与最终 result 由 hub 分配 seq |

### 8.2 WebSocket 事件（服务端 → 客户端）

| 事件 | 含义 | 客户端动作 |
|---|---|---|
| `im:poke { since }` | "有新数据，来拉"（轻量） | 触发一次增量 `GET /sync` |
| `im:message { message }` | 新蒸馏消息（尤其 assistant result 完成） | 落本地库；若非当前会话/未读 → **红点 + 本地通知** |
| `im:read { conversationId, deviceId, lastReadSeq }` | 另一设备已读位置变化 | 更新本地 readCursor → **清红点** |
| `im:conversation { conversation }` | 会话元数据变化（标题/置顶/免打扰/lastActivity） | 更新本地会话 |

`im:message` 内联推送小消息；超过阈值则只发 `im:poke` 让客户端拉，避免 WS 帧过大。

### 8.3 发送流程（乐观 + 队列）

1. 客户端生成 `clientMsgId`，本地插入 `deliveryState: sending` 的 user 消息，立即上屏。
2. 写入**本地持久化上传队列**（PowerSync 模式），经 `POST /send` 或现有 WS chat 路径发往服务端。
3. 服务端驱动 Claude query；user 消息蒸馏入库并分配 seq → 回带 `clientMsgId` ↔ `seq/id` 对账 → 客户端置 `sent`。
4. assistant result 完成 → `im:message` 推送 → 红点/通知。
5. 失败 → `deliveryState: failed`，队列支持重试。

### 8.4 增量同步与游标

- `cursor` = 全局或每会话 `seq` 高水位。客户端持久化"自己设备的 `lastSyncSeq`"。
- 重连 / 切端只拉差量；首次进新设备某超长会话时，首屏只同步最新一页让其立刻可用，其余历史后台分页回填，不阻塞 UI。

---

## 9. 服务端 IM hub 设计（子系统 1 契约面）

落在现有 Node 服务真实结构上（`better-sqlite3` + `schema.ts`/`migrations.ts`/`repositories/` + `modules/websocket/` + `routes/` + `services/`）。

### 9.1 新增 IM 状态库（SQLite 表，走现有 migrations）

| 表 | 关键列 | 说明 |
|---|---|---|
| `im_conversations` | id, contact_id, provider_id, title, last_seq, last_activity_at, is_pinned, is_muted | 会话元数据 + 用户态 |
| `im_messages` | id, conversation_id, seq, role, kind, content, tool_trace_count, raw_ref_start, raw_ref_end, created_at | 蒸馏消息（derived cache，seq 在此分配以保证稳定与跨端一致） |
| `im_read_cursors` | conversation_id, device_id, last_read_seq, updated_at | 每设备每会话已读位置 |
| `im_devices` | device_id, last_sync_seq, last_seen_at | 设备同步水位（可选） |

> `im_messages` 是 jsonl 的派生缓存/索引，**非源真相**——hub 拥有它只为 seq 稳定 + 同步廉价。jsonl 仍是 RAW 源真相。

### 9.2 新增模块

- **蒸馏服务** `services/im-distill.service.ts`：监听 / 解析 session jsonl（复用现有 `recent-sessions.service` / `sessions.db` 的扫描能力），按第 6 节规则映射为蒸馏消息，分配单调 seq，落 `im_messages`，记录每轮 `toolTrace` 的原始条目区间。
- **同步路由** `routes/im.js`（或 `.ts`）：实现 §8.1 全部 REST 端点；遵守仓库的 boundaries 规则，跨模块经 barrel `index.ts` 暴露。
- **WS 事件**：在 `modules/websocket/` 增加 IM 事件类型（`im:poke` / `im:message` / `im:read` / `im:conversation`），沿用"回调注入、不在 WS 模块内 import 业务"的现有边界约定。
- **推送复用**：Web/PWA 通知复用**现有 VAPID web push 基建**（`repositories/push-subscriptions.ts`、`repositories/vapid-keys.ts`、`services/notification-orchestrator.js`、`services/vapid-keys.js`）；iOS 本阶段走客户端本地通知（不动服务端 APNs）。

### 9.3 不做（YAGNI / 避坑）

- ❌ 不引 MQTT / Mars / protobuf —— 用 WS + JSON。
- ❌ 不另起独立 Java IM 服务 / minio / janus。
- ❌ 不引入付费闭源 Web SDK —— 协议开放。
- ❌ 不把消息源真相从 jsonl 迁进 DB。
- ❌ 不引远程 APNs（本阶段）。

---

## 10. 完整记录查看器（性能要点）

唯一可能含大 tool 输出的地方，必须防卡：

1. **分页**：`anchor + numBefore/numAfter`（Zulip 式）+ `hasMore`。
2. **懒加载**：进入只拉最近一页，向上滚动按游标续拉。
3. **大 blob 引用化**：列表项只带摘要 + `entryId`，点开某条才 `GET /transcript/blob/:entryId` 拉完整内容。
4. **虚拟化渲染**：iOS `LazyVStack` / Web 虚拟列表 / macOS `List` 惰性。

IM 聊天流因是蒸馏的，本身无需这些补救。

---

## 11. 通知与小红点

- **数据源**：蒸馏库的 assistant `result` 消息落库即"AI 回复"事件。
- **未读计算**：客户端 `unreadCount = conversation.lastSeq − localReadSeq`，本地即时，无需拉全量消息（Zulip 思路）。
- **跨端清红点**：本端进入会话 → `POST /read` 上报 → 服务端广播 `im:read` → 其他设备清红点。
- **通知触发**：收到 `im:message`(result) 且非当前前台会话且会话未 mute → iOS `UNUserNotificationCenter` 本地通知 + app icon badge；Web 走现有 VAPID push。

---

## 12. 各端落地映射（后续子系统预览）

| 端 | core | 存储 | UI |
|---|---|---|---|
| iOS（子系统 3） | Swift ChatKit-core（同步客户端 + WS + 上传队列） | SwiftData 蒸馏镜像 | ChatKit-UI-iOS：微信式 4 Tab、气泡、灰色工具条、本地通知 + badge |
| macOS（子系统 4） | 同上（共享） | SwiftData | **原生 SwiftUI**（ChatKit-UI-macOS 接新 core）——**仅在视觉样式上借鉴 vue-pc-chat 的 Electron PC 外观，绝不走 Electron** |
| Web（子系统 5） | TS core（同步客户端 + WS + 队列） | IndexedDB 蒸馏镜像 | 现有 `src/components/wechat/*` 接新协议 |
| Windows（子系统 6） | 复用 Web | 复用 Web | Electron 壳（参考 vue-pc-chat 的打包路线，不要其付费 SDK） |

> **macOS 与 Windows 的关键区别**：Windows 走 Electron 复用 Web；**macOS 坚持原生 Swift/SwiftUI**，只把 vue-pc-chat 的 Electron 桌面布局当**视觉参考**（双栏、会话列表、气泡风格），实现仍是纯原生。

野火三层切分映射到我们：`ChatKit-core`(=chatclient) / `ChatKit-UI`(=chatuikit) / app 目标(=chat)。现有 ChatKit 的 UI 与 macOS AppKit 耦合，需按此三层重新切干净，使 core 能 macOS+iOS 共用。

---

## 13. 非目标 / 暂不做

- 远程 APNs 推送（本阶段本地通知 + badge）。
- 端到端加密 / SqlCipher 本地库加密（单用户测试阶段）。
- 群聊 / 多用户 / 在线状态 presence（概念上联系人=项目，无真人对端）。
- 音视频 / 文件对象存储服务。
- 重写认证（测试阶段已注释/跳过，协议预留位但不阻塞）。

---

## 14. 风险与待解

1. **蒸馏规则边界**：哪些 assistant 文本算"最终回复"、流式过程如何归并为一条 result —— 需在子系统 1 实现时对照真实 jsonl 样本细化。
2. **seq 分配与 jsonl 重扫一致性**：jsonl 被外部（Claude Code CLI）追加写时，蒸馏服务的增量扫描与 seq 单调性需保证幂等。
3. **首次大会话同步体验**：后台回填策略需实测超长会话。
4. **多端时钟 / 排序**：以服务端 seq 为唯一排序基准，避免依赖客户端时间。

---

## 15. 下一步

本 spec（子系统 0 + 1 契约）经用户审阅批准后，调用 writing-plans 为**子系统 0 + 1** 生成详细实现计划（IM 状态库迁移、蒸馏服务、同步 REST、WS 事件）。其余子系统在地基落地后各自展开。
