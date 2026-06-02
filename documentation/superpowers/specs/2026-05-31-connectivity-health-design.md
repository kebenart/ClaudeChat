# 四端连接健康度 (Connectivity Health) + watch 图标修复 — Design

> Status: approved (2026-05-31). Next: writing-plans.

## Goal

让 ClaudeChat 的四个端 (Web / macOS / iOS / watchOS) 在服务端离线、网络异常、连接"假死"时，给用户**可见的状态与反馈**——而不是像现在这样"什么都看不到"。顺带修复 watchOS 缺失的统一 App 图标。

## Problem (current state)

底层连接状态其实存在，但没暴露给用户、且只有二态：

| 端 | 连接状态 | 自动重连 | 用户能看到什么 |
|---|---|---|---|
| Web | `isConnected` bool | 有，固定 3s | 我-tab "已连接/未连接"；仅 sync 失败时弹一次错误 toast |
| iOS | `isConnected` observable | 有 | 我-tab 资料卡 "已连接/未连接" |
| watch | `isConnected` observable | 有 | 仅设置 sheet 里有一行"已连接/未连接" |
| macOS | socket 有(1–30s 退避)，但 `AppViewModel` **从不暴露** | 有 | **完全静默**——断开毫无提示 |

核心缺口：(1) macOS 什么都不显示；(2) 全端只有二态，没有"**重连中…**"中间态、没有断开/恢复的**切换反馈**；(3) Web 没有心跳，服务端崩溃但 socket 未干净关闭的"**假死**"连接会一直显示"已连接"，直到用户发消息才发现。

watchOS 图标：watch target **完全没有 asset catalog**(无 `Resources/`、无 `Assets.xcassets`、无 `AppIcon.appiconset`)，但 build settings 仍引用 `AppIcon`，于是 watchOS 回退到占位图标。

## Core concept — 统一三态模型

各端把二态 `isConnected` 升级为三态 `ConnectionState`：

| 状态 | 含义 | 进入条件 |
|---|---|---|
| `online` | socket 已连 **且** 心跳健康 | 连接成功 / 收到 pong |
| `reconnecting` | 丢了服务端，自动重连进行中(设备仍有网) | socket 关闭 / 心跳看门狗触发 |
| `offline` | **设备本身**没网 | Web `navigator.onLine===false` / Apple `NWPathMonitor` 无可用路径 |

- `isConnected` 保留为派生值 `=== 'online'`，下游全部不动，零破坏。
- **持久信号** 放在**个人中心**(三态 + 重连中显示第 N 次尝试)。
- **切换横幅** 是**瞬态**：只在边沿弹——断开时弹"连接断开，正在重连…"，恢复时弹"已重新连接"(~3s 自动消失)。中间期不常驻横幅，靠个人中心承载。(= 选项 A，非常驻条。)

## Architecture

### 1 · Web (`src/` + `server/`)

- **`src/contexts/WebSocketContext.tsx`**
  - 新增 `connectionStatus: 'online'|'reconnecting'|'offline'` 与 `reconnectAttempt`，经 context 暴露。
  - 用**指数退避 + 抖动**(1→2→4→8→16→30s 上限)替换固定 3s。退避计算抽成纯函数 `computeBackoffDelay(attempt)` 便于单测。
  - **心跳看门狗**：每 ~25s 发 `{type:'ping'}`；若 ~10s 内无任何入站帧(含 `{type:'pong'}`)，判定 socket 已死 → close → 重连。这是捕获"假死"服务端的关键。
  - 监听 `window` 的 `online`/`offline` → 无网时置 `offline`，恢复时立即重连。
- **`server/modules/websocket/`**：chat WS 消息处理器对 `{type:'ping'}` 回 `{type:'pong'}`(连接级、与 provider 无关；浏览器无法发原生 WS ping 帧，所以必须有这条应用级 pong)。
- **`src/components/wechat/WeChatMeTab.tsx`**：指示器升级为三态(绿 已连接 / 黄 重连中…第N次 / 灰 已离线)。
- **切换横幅**：一个小控制器(放 `IMContext` 或 `AppContent`)监听 `connectionStatus` 边沿 → 断开 `imToast('连接断开，正在重连…','error')`、恢复 `imToast('已重新连接','info')`。复用现有 `imToast`/`IMToast`，不新增 UI 原语。

### 2 · Apple 共享核心 (`apple/Sources/ChatKit/`)

- 在 ChatKit 定义 `ConnectionState` enum(`online`/`reconnecting`/`offline`)。
- **`ChatSocket`** 已有状态机 + 退避(1–30s) + `reconnectAttempt`，只是没到 UI。改动：
  - 连接状态变化经**现有 `events` AsyncStream** 以新 case `ServerEvent.connection(ConnectionState)` 抛出(干净——所有 app model 已消费该流)。
  - 加**空闲看门狗**(超时无入站帧 → 强制重连)，镜像 Web 心跳；ChatSocket 同样发 `{type:"ping"}`。
  - 加 **`NWPathMonitor`** 驱动 `offline` 状态。

### 3 · Apple UIs

各 app model 暴露 observable `connectionState`、派生 `isConnected`、从 `ServerEvent.connection` 流更新、在边沿触发横幅。

- **iOS** (`apple/ios/Sources/MeTab.swift` + `IOSAppModel.swift`)：三态指示器 + 由 `connectionState` 边沿驱动的轻量瞬态**横幅 overlay**。
- **macOS** (`AppViewModel` + `apple/Sources/ChatKitUI/Sidebar/MeSidebar.swift` + `MainWindowView`)：改动最大——`AppViewModel` 必须**暴露 `connectionState`**(今天只在日志里读 `socket.isConnected`)；`MeSidebar` 补上它目前缺失的指示器；`MainWindowView` 加同样的横幅。补齐"macOS 完全静默"。
- **watch** (`apple/watch/Sources/ConversationListView.swift` + `WatchAppModel.swift`)：把状态搬到**主列表**(仅在 `reconnecting`/`offline` 时出现的顶部状态行)，而非埋在设置 sheet。屏幕小，顶部行**即横幅**，不另做 overlay；`ServerSetupView` 保留原行。

### 4 · watch App 图标(打包修复)

- 新增 `apple/scripts/make-watch-icon.sh`：用 `sips` 把统一源 `apple/Sources/ClaudeChat/AppIcon.png`(2048²)缩成 watchOS 所需尺寸，写入 `apple/watch/Resources/Assets.xcassets/AppIcon.appiconset/` + `Contents.json`。
- `apple/watch/project.yml`：加 `Resources` build phase(`buildPhase: resources`)，让 xcodegen 接上 asset catalog(build settings 已引用 `AppIcon`)。
- 重新生成工程 + 构建确认显示统一图标。

## Testing

- 纯函数加单测：`computeBackoffDelay(attempt)`(Web，Node test runner via tsx) 与连接状态转移映射。
- UI 接线(四端)由 typecheck/lint/build + 手动断连验证(杀本地 server → 看横幅 + 个人中心翻"重连中" → 重启 server → 看恢复)。

## Scope notes (YAGNI)

- **不加**手动"立即重连"按钮——全自动。
- 横幅瞬态/仅边沿，**不是**常驻条。
- iOS 已有 send-fail + 前台自动重连，保留，只加看门狗 + 状态暴露。
- macOS 本地 ad-hoc 运行，不改其签名；只补连接状态 UI。
- 签名/bundle-id 问题(已在本会话单独修复)不属本设计范围。

## File map

**Web/server**
- `src/contexts/WebSocketContext.tsx` — 三态 + 退避 + 心跳看门狗 + online/offline
- `src/contexts/WebSocketContext.backoff.ts`(新) — 纯 `computeBackoffDelay` + 测试
- `server/modules/websocket/` — ping→pong
- `src/components/wechat/WeChatMeTab.tsx` — 三态指示器
- `src/contexts/IMContext.tsx` 或 `src/components/app/AppContent.tsx` — 边沿横幅控制器

**Apple 核心**
- `apple/Sources/ChatKit/` — `ConnectionState` enum、`ServerEvent.connection`、ChatSocket 看门狗 + NWPathMonitor

**Apple UI**
- iOS: `apple/ios/Sources/IOSAppModel.swift`、`MeTab.swift`、横幅 overlay(新)
- macOS: `AppViewModel`、`apple/Sources/ChatKitUI/Sidebar/MeSidebar.swift`、`MainWindowView`、横幅(新)
- watch: `apple/watch/Sources/WatchAppModel.swift`、`ConversationListView.swift`

**图标**
- `apple/scripts/make-watch-icon.sh`(新)
- `apple/watch/Resources/Assets.xcassets/AppIcon.appiconset/`(新)
- `apple/watch/project.yml`
