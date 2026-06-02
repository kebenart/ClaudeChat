# 多端 IM 架构 — 项目状态与进度（持久化记录）

> 本文件是跨 compact 的**权威进度记录**。最近更新：2026-05-29。分支 `feat/im-server-hub`（基于 `main`，**未合并、未 push**，截至本记录 51 个提交）。

## 一句话目标
把这个 Claude Code UI fork 的整体架构按**即时通讯（微信式）App** 重新设计，覆盖 **macOS / iOS / Web，未来 Windows**；服务端为中心 hub，客户端本地优先；每个 Claude session = 一个聊天会话，项目 = 联系人。

## 关键设计决策（已锁定）
- 会话 = Claude session;联系人 = 项目/工作目录。
- **本地优先 + 服务端为中心 hub**(微信式跨端同步,服务端是权威真相)。
- **方案 C 两层存储**:`*.jsonl` 仍是消息源真相(零迁移);新增轻量 IM 状态库(蒸馏消息 + 已读游标 + 会话元数据)。
- **蒸馏**:只留用户消息 + Claude 最终回复;工具/思考剔除,折叠成灰色"执行了 N 个操作"小条(`toolTrace.count` = tool_use 个数);完整原始记录走单独的分页查看器。
- **跨端未读**:`unread = max(0, lastSeq − 各设备已读游标的最大值)`(单用户,任一端读 → 各端清红点)。
- **同步游标**:服务端 `rev`(全局单调,insert 和原地更新都自增)→ 流式增长内容能被增量重新下发。
- **状态管理**:Swift 端 MVVM(复用 ChatKit ViewModel),不引 Redux/TCA。
- **通知**:本地通知 + 角标(iOS UNUserNotificationCenter / Web 现有 VAPID),暂不引远程 APNs。
- **保留策略**:IM 会话只保留 **3 天**(`IM_RETENTION_DAYS=3`);活跃会话 `last_activity_at` 一直刷新故永不被清;**删除联系人 → 级联彻底删除**其所有会话+消息+游标。
- **主要参考**:野火 IM(分层/多端同步,避开 MQTT/Mars/付费 SDK)+ Zulip(未读同步 + anchor 分页)+ Matrix(存储抽象)+ PowerSync/Replicache(上传队列/游标拉取)。**移除 WeChat-SwiftUI 参考。**

## 文档位置
- 地基设计 spec:`docs/superpowers/specs/2026-05-29-multiplatform-im-architecture-design.md`
- 实现计划:`docs/superpowers/plans/2026-05-29-im-server-hub.md`(子系统1)、`-im-web-client.md`(5)、`-im-swift-core.md`(2)、`-im-ios-app.md`(3)。

## 子系统状态
| # | 子系统 | 状态 | 验证 |
|---|--------|------|------|
| 0 | IM 协议 + 数据模型契约 | ✅ | 体现在各端代码 |
| 1 | 服务端 IM hub(Node) | ✅ QA 通过 | 96 后端测试;14/14 接口实测 |
| 2 | Swift IM core(macOS+iOS 共享) | ✅ QA 通过 | 152 swift 测试 |
| 5 | Web 端(React) | ✅ QA 通过 | 10 前端单测 + typecheck;浏览器实跑 |
| 3 | iOS app(微信式 UI + 本地通知 + 红点) | ✅ | iOS 模拟器 BUILD SUCCEEDED |
| 4 | macOS app 接 IM 核心 | ✅ | swift build + 152 测试 |
| 6 | Windows(Electron 复用 Web) | ⬜ 未开始 | — |

### 各端实现要点
- **服务端(1)**:`server/modules/database/`(im_conversations/im_messages/im_read_cursors 表 + `imDb` 仓库,migrations);`server/services/im-distill.service.ts`(蒸馏纯函数)、`im-ingest.service.ts`(jsonl→落库+`ingestAndBroadcast`)、`im-events.service.ts`(WS 帧+广播)、`im-backfill.service.ts`(启动回填最近3天)、`im-retention.service.ts`(3天清理);`server/routes/im.js`(sync/conversations/messages/read/state/transcript/blob);watcher 钩子 `setSessionIndexedHook`(providers 模块)→ index.js 接 ingestAndBroadcast;`index.js` 启动跑回填 + 每小时 retention 清理;`project-delete.service.ts` 强制删除时 `imDb.deleteConversationsByContact`。
- **Swift core(2)**:`apple/Sources/ChatKit/IM/`(ImDTOs/ImModels(@Model)/ImStorage(Storage actor 扩展)/ImSyncEngine(applySync/applyFrame/computeUnread)/DeviceIdentity);`Events.swift` 加 `imMessage/imRead/imPoke`;`APIClient` 加 IM 端点 + `fetchImTranscript`。**ChatKit 已拆分**:`ChatKit`(iOS-safe 核心)/ `ChatKitUI`(macOS AppKit UI)/ `ClaudeChat`(exe)。
- **Web(5)**:`src/services/im/`(protocol/store(InMemory+IndexedDb)/syncEngine/api/urls/deviceId);`src/contexts/IMContext.tsx`(WS连接后同步+帧消费+useIM);`AppContent.tsx`(红点来自 IM、前台 auto-markRead、进会话 markRead);`WeChatChatPane.tsx`(历史读蒸馏流);`WeChatTranscriptSheet.tsx`。
- **iOS(3)**:`apple/ios/`(xcodegen `project.yml`,只依赖 ChatKit 核心);`IOSAppModel`(同步+WS+通知+markRead)、`RootTabView`/`ChatListView`/`ChatDetailView`(发送 composer)、`LoginView`(含 TOTP + 跳过直连 + 持久化)、`TranscriptSheet`、`ContactsView`、`IOSNotifications`。
- **macOS(4)**:`apple/Sources/ChatKitUI/ViewModels/IMController.swift`(包 ImSyncEngine);`AppViewModel` 接 IM 同步/markRead/`mergedUnreadCounts`;`SidebarView` 红点取 merged;`main.swift` 注入 IMController。

## QA 审查中发现并修复的真实 bug(历史)
- Task2:`toolTrace.count` 误把 call+result 算 2(应=tool_use 个数)。
- Task3:`listMessages` 无锚点排序错乱(严重);conv 元数据回退;`/sync` pk 游标无法回传原地更新 → 改 `rev` 游标。
- 流式重复气泡(严重):result 原先用最后一条 assistant uuid 做 key,每次重扫新插行 → 改"该轮第一条 assistant uuid 稳定 key + UPSERT 原地更新"。
- 路由 `parseInt(x)||default` 把显式 `0` 吃掉(`numAfter=0→40`)→ `intParam` 尊重 0。
- iOS:冷启动鉴权前同步 401 不重试 → 改 WS 连接后同步;前台会话红点不自清 → auto-markRead;IndexedDB read-cursor 单事务隐患 → 拆读写事务。
- Swift:未同步会话收到实时 im:message 不显示 → applyFrame 建占位会话。

## 最近进展(本会话末尾)
1. **接口全测**:服务端单跑(临时端口),14/14 REST 接口通过,发现并修复 `intParam` 0-bug。
2. **保留+级联**(用户新需求):3 天保留清理(启动+每小时)+ 删除联系人级联删会话。96 测试通过。
3. **启动回填**:`im-backfill.service` 把最近 3 天会话蒸馏进库(否则列表空等 jsonl 变化)。
4. **当前正在运行的 dev server(供浏览器测)**:
   - **后端 3011 + 前端 5173**(`SERVER_PORT=3011 VITE_PORT=5173 DEV_AUTH_BYPASS=1 npm run dev`,后台托管进程)。
   - **浏览器开 http://localhost:5173**(免登录),看到约 17 个最近会话(3 天保留生效)+ 红点 + 蒸馏流 + 完整记录。
   - **注意**:3001 上是 launchd 托管的生产服务(老 build),故意没动;dev 跑在 3011,vite 自动代理,互不干扰。

## 待办 / 下一步
- 用户在浏览器/Xcode 实跑验证视觉与端到端连通,反馈后迭代。
- 子系统 6:Windows(Electron 壳复用 Web)。
- 可选:合并/开 PR 落地(51 commits)。
- 已知非阻塞:发送走现有 WS chat 路径(未新造);historical 向上翻页 UI;通讯录/发现/我部分 Tab 仍简;iOS/macOS 仅编译+单测级验证,未真机视觉验证;大 blob 完整拉取仅占位。

## 如何恢复工作
- 跑后端测试:`npx tsx --tsconfig server/tsconfig.json --test "server/**/*.test.ts"`(96)
- 跑 Swift:`cd apple && swift test`(152)
- 跑 Web 单测:`npx tsx --tsconfig tsconfig.json --test "src/services/im/**/*.test.ts"`(10)
- iOS 编译:`cd apple/ios && xcodegen generate && xcodebuild -scheme ClaudeChatIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath .build build`
- 浏览器测:`SERVER_PORT=3011 VITE_PORT=5173 DEV_AUTH_BYPASS=1 npm run dev` → http://localhost:5173

## 追加进展(2026-05-29 深夜,自主连夜开发)
**网页版打磨**(已提交 `feat(im-web)` 等):微信绿配色双主题、qqe9 226 张可爱/二次元头像库(localStorage 唯一分配不重复)、联系人折叠+3天保留+去空路径、发起会话/添加联系人弹窗、默认全批准(bypassPermissions)、历史直连服务端(弃 IndexedDB 改 InMemory 同步,根治陈旧/空/卡死)、完整记录折叠工具+最新优先、会话去重、在线绿点、预览、对账兜底。
**macOS 全量移植**(`feat(im-macos)`):头像库(共享 ChatKit)、气泡/流式头像按会话 id、bypassPermissions、3天保留(SessionListViewModel)、联系人分组可折叠。`swift build` 通过。
**iOS 全量移植**(`feat(im-ios)`):IOSAvatar 图库头像(列表/联系人/气泡)、bypassPermissions、TranscriptSheet 工具折叠+最新优先、ImTranscriptEntry 加 role/kind。`xcodebuild` BUILD SUCCEEDED。
**服务端**(`feat(im)`):watcher 原生 fsevents(去 6s 轮询延迟)、transcript role/kind 分类 + 无 anchor 返回最新页。
**门禁**:96 后端测试全过 · 网页 typecheck/lint 绿 · Mac swift build 绿 · iOS xcodebuild 绿。AvatarGallery 移入 ChatKit 核心供 Mac+iOS 共享。
