# Hook 驱动的 IM 摄取重构 — 设计稿(仅设计,未实现)

> 目标:把"消息怎么进数据库"和"IM 怎么收发"彻底分离。Hook 把消息写进库,IM(服务端 API + 四端)只是数据库之上的纯消息层——像真正的 IM/微信:联系人(=Claude)发消息进库,IM 负责投递。不再让 IM 去解析 Claude 的 jsonl 文件,也不要流式。

## 1. 原则(用户定调)
- **hook 数据进入数据库**:消息由 hook/生命周期事件在**回合边界**权威落库,而非事后解析文件猜。
- **IM 只和服务器交互**:四端只走服务端 REST/WS(/sync、/send、im:poke),**不碰 jsonl、不耦合 Claude 文件产物**。
- **分离 / 解耦**:摄取层(Claude 侧)与投递层(IM 侧)互不依赖。
- **不要流式**:回合完成才出现一条助手气泡,像普通聊天软件。

## 2. 现状与问题(基于代码)
- 摄取 = `chokidar` 监听 `~/.claude/projects/**/*.jsonl` → `distillJsonl` → `imDb.insertMessages` → 广播 `im:message`(`im-ingest.service.ts` / `sessions-watcher.service.ts`)。
- **用户气泡靠 jsonl 反推**:`distill` 用一张**硬编码前缀黑名单**剔除 harness 注入的"伪用户"行(slash 展开、`<user-prompt-submit-hook>`、`Caveat:…`、中断标记、system-reminder)。脆——新格式就漏成幽灵气泡(`af65f1f` 即此类修复)。
- **"流式"是副作用**:助手 `result` 用稳定 key,每次 jsonl 追加就 UPSERT 同行 + 重广播,内容越长广播越多 → 四端每次整窗 reload → **卡顿根因**。
- 现成可复用件:`imDb.insertMessages(conversationId, DistilledMessage[])`(对 `(conversation, sourceId)` 幂等、分配单调 seq)、`buildImMessageEvent(row)` + `broadcastImEvent(frame)`(`im-events.service.ts`)、`distillJsonl`(只在回合末跑一次仍有用)。
- 关键事实:`claude-sdk.js` 已设 `sdkOptions.settingSources = ['project','user','local']`(会加载 settings 里的 hooks),且已有 `sdkOptions.hooks`(目前挂了 `Notification`),SDK 版本 `@anthropic-ai/claude-agent-sdk ^0.2.116`(支持 `UserPromptSubmit` / `Stop` 等 hook 事件);回合结束在 `claude-sdk.js:745` 发 `kind:'complete'`。

## 3. 目标架构

```
                ┌─────────── 摄取层(Claude 侧)───────────┐
  用户发送 ─┐    │  UserPromptSubmit hook → 记 user 消息      │
  (App/终端)│    │  Stop / complete      → 记 assistant 消息  │   → imDb(权威落库, 幂等 sourceId)
           └───►│  (回合边界, 结构化事件, 不解析文件)        │           │
                └───────────────────────────────────────────┘           │ broadcast im:message / im:poke
                                                                          ▼
                ┌─────────── 投递层(IM 侧, 不变)──────────┐     四端 ← /sync 拉取 + WS poke
                │  服务端 REST/WS(/sync /send /state …)     │     (只和服务器交互, 不碰 jsonl)
                └───────────────────────────────────────────┘
```

- **摄取层**只负责"把回合边界的消息写进库 + 广播一次"。
- **投递层**(IM 服务端 API + 四端)完全不变契约:四端只 /sync 拉、/send 发、收 im:poke。

## 4. 摄取来源分两类

| 来源 | 触发 | user 消息 | assistant 消息 |
|---|---|---|---|
| **App 会话**(IM 发送 → WS `claude-command` / REST `/send` → SDK query) | 程序化 hook(`sdkOptions.hooks`,**保证触发**) | `UserPromptSubmit` 拿 `prompt` 直接记;或发送入口已有 `command`+`clientMsgId` 直接记 | `Stop`(或 `kind:'complete'` 那一刻)记**最终文本一次** |
| **终端/IDE 会话**(用户直接跑 `claude`) | `~/.claude/settings.json` 的 settings hook | `UserPromptSubmit` hook → POST 到服务端 ingest 端点 | `Stop` hook 读 transcript 末轮(一次性 distill)→ POST |

> 因为 `settingSources` 含 user/project/local,**settings hook 理论上对 SDK 会话也会触发**——若实测如此,可只用一套 settings hook 通吃两类;否则用"App=程序化 hook + 终端=settings hook"的混合。两路都经 `imDb.insertMessages` 幂等去重(同 `sourceId`),即便重复触发也不会重记。**这是实现前唯一需实测确认的点。**

## 5. 关键决策
1. **user 消息权威化**:在回合边界由 hook 记入库(`role=user, kind=text, sourceId=clientMsgId 或 prompt uuid`)。**distill 不再负责 user 气泡**,黑名单对 user 失效即可删一半脆性。
2. **assistant 只记一次**:在 `Stop`/`complete` 记最终文本(`role=assistant, kind=result|error, sourceId=该回合稳定 id`)。**取消逐追加重广播**。
3. **气泡只存 text/result/error**:工具行(tool_use/tool_result/thinking/meta)**不进 im_messages**(完整记录另走 transcript 接口直读 jsonl)。→ 顺带根治"reload 读大 blob"卡顿。
4. **文件监听降级**:只在**服务启动时回填**历史(distill 最近 N 天);**移除实时逐追加广播**。
5. **客户端**:契约不变,仍只连服务端;因为每回合只广播一次,四端"流式 reload 风暴"自然消失——客户端只在 `lastSeq` 跳变(=新回合)整窗刷一次。基本无需改客户端(去掉对流式的任何特判即可)。

## 6. 数据流(一次问答)
1. App 发送 → `/send`/`claude-command` → 服务端**立即记 user 消息**(权威)+ 广播 → 四端瞬时看到自己的气泡(乐观气泡按 `clientMsgId` 对账)。
2. SDK 跑 Claude(工具、思考……**期间不向 IM 广播**)。
3. 回合结束(`Stop`/`complete`)→ 取最终助手文本 → **记一次 assistant 消息** + 广播 `im:message`。
4. 四端收到 poke/消息 → /sync → 一条助手气泡出现(其间显示"正在输入…")。

## 7. 风险 / 待确认
- **[必测] settings hook 是否对 SDK 会话触发**(决定一套 hook 通吃 vs 混合)。
- **终端 assistant 文本来源**:`Stop` 只给 `session_id`+`transcript_path`,需读末轮 → 复用 `distillJsonl` 取最后一条 `result`(回合已完成,稳定)。
- **去重**:多路触发靠 `insertMessages` 的 `sourceId` 幂等;需统一 `sourceId` 规则(user 用 clientMsgId/prompt-uuid,assistant 用回合首条 assistant uuid)。
- **历史/回填**:`distill` + backfill 保留,仅作启动回填与"完整记录"接口;不再实时。
- **鉴权**:终端 hook 的 ingest 端点走 loopback 信任或 env 共享密钥(hook 在本机,POST 127.0.0.1)。
- **乱序/竞态**:user 先于 assistant 落库,seq 单调;乐观气泡对账改用 `clientMsgId`(比现在的内容字符串匹配更稳)。

## 8. 实施阶段(待批准后再开发)
- **P1**:App 会话——发送入口记 user、`complete` 记 assistant 一次;移除文件监听实时广播(保留启动回填)。→ 覆盖主用例 + 去流式 + 修卡顿。
- **P2**:`settings.json` hook + ingest 端点——覆盖终端/IDE 会话(先实测 settingSources 是否已让 SDK 会话也触发,以定 P1 是否可被 P2 取代)。
- **P3**:客户端清理——去掉任何对流式的特判;乐观对账改 `clientMsgId`;确认四端一致。

## 9. 缓解措施(应对"慢"与"大")

### 9.1 不流式消息体,但保留廉价实时进度(选定:粗粒度)
- 回合期间**不广播消息体**,只发**轻量 status 帧**(非消息、不进 im_messages、不触发整窗 reload)。
- **粒度(选定)**:`正在输入…` + **粗粒度步骤**——`执行了 N 个操作` / `正在运行 <当前工具>`(来源:SDK 的 PreToolUse/PostToolUse 计数 + 当前工具名)。
- 客户端把它显示在"正在输入…"那一行(typing row),几乎零成本;回合结束才落 1 条 assistant 气泡。
- 效果:长 agentic 任务"看着在动",但无流式重广播 / 无 reload 风暴。

### 9.2 长消息:预览 + 懒加载全文(选定:懒加载)
- **气泡只渲染预览**:超过阈值(参考手表 ~220 字 / 8 行)折叠成预览 + "查看全文",**四端统一**。
- **`/sync` 只带预览**(`last_message_preview` + 截断的气泡内容),**不带超大正文**——避免列表/同步载荷过大。
- **全文懒加载**:点"查看全文"时才按 `messageId` 拉完整正文(新增 `GET /api/im/messages/:id/content` 或复用 transcript 接口),全文页是独立滚动视图,多长都不卡。
- 结论:本方案**不增大消息体、反而减少每回合的渲染/同步工作量**;唯一残留的"单条超长"风险由预览+懒加载消除。

### 9.3 交互/选择类消息(permission_request / AskUserQuestion / ExitPlanMode)
- **与普通消息不同**:回合**中途**发生且**阻塞 Claude 等待用户** → 不能等 Stop 落库,必须**实时投递**(本设计"回合内不广播消息体"的**唯一例外**)。
- **作为交互卡片消息**:新 kind(如 `choice`),带结构化选项;**实时广播 + 同时落库**(历史可见)。
- **回应通道**:
  - Web/iOS/macOS:现有 `claude-permission-response`(工具审批已是此机制);为 AskUserQuestion/Plan 增对应响应帧。
  - **手表(REST)**:新增 `POST /api/im/.../respond` → 服务端 `resolveToolApproval`/解阻塞 → Claude 继续。
- **状态机**:`pending` →(用户选择 / 超时自动)→ 更新为"已允许 / 已选择 X / 已超时自动执行",卡片变终态(似微信卡片"已完成")。工具审批 10 分钟超时自动放行;AskUserQuestion/ExitPlanMode **无限等**(挂成一条未处理卡)。
- **两种投递模式总览**:普通消息 = 边界落库 + 广播一次;交互卡片 = 中途实时广播 + 回应通道。

## 10. 影响面
- 改:`server/claude-sdk.js`(记 user/assistant)、`sessions-watcher`/`im-ingest`(降级为回填)、新增 ingest 端点 + hook 脚本 + settings 配置;客户端基本不动。
- 不改:四端 IM 收发契约、/sync /state /send、会话状态同步(pin/mute/fold/delete)。
