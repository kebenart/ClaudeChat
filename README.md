<div align="center">
  <img src="docs/assets/app-icon.png" alt="ClaudeChat" width="84" height="84" />
  <h1>ClaudeChat</h1>
  <p>把 Claude Code 会话变成一场对话 —— 微信式的多端 IM。<br/>
  每个会话是一个聊天,每个项目是一个联系人。<b>Web / macOS / iOS / watchOS</b> 四端实时同步,本地优先,服务即枢纽。</p>
</div>

---

## ✨ 是什么
[官网](https://kebenart.github.io/ClaudeChat/)

ClaudeChat 把你所有的 Claude Code 会话,组织成一个真正的 IM:

- **会话即聊天** — 蒸馏掉工具/思考噪音,只留干净的来回对话。
- **四端实时同步** — 服务即枢纽,`im:*` WebSocket 广播。一处已读 / 置顶 / 删除,四端秒级一致。
- **本地优先** — 原始 `~/.claude/**/*.jsonl` 始终是事实来源,服务端只维护一份轻量 IM 状态库;数据从不离开你的机器。
- **微信式手感** — 折叠聊天、静音、置顶、删除会话、备注名、黑名单屏蔽,全端同步。
- **安全私有** — 密码 + TOTP 双因素,FRP 内网穿透 + TLS 终结;服务只监听环回,公网入口由你掌控。

## 📱 四个端

| 端 | 技术 | 说明 |
|----|------|------|
| **Web** | React + Vite | 服务端直接托管,浏览器打开即用 |
| **macOS** | SwiftUI | 三栏原生窗口 |
| **iOS** | SwiftUI | 微信式聊天列表 + 会话详情 |
| **watchOS** | SwiftUI | 独立手表 App,抬腕看回复、下拉刷新 |

Apple 端共享一套 Swift 核心(`apple/Sources/ChatKit`):Storage(SwiftData)、ImSyncEngine、APIClient、ChatSocket。

## 🏗 架构

```
客户端 (4 端)            云服务器 (公网)             家里 Mac (本机)
─────────────  ──→  ─────────────────  ──→  ─────────────────
Web / macOS         nginx · TLS 终结          frpc 主动外拨隧道
iOS / watchOS       WebSocket 升级            Node 服务 · 环回
HTTPS / WSS         frps · FRP 服务端          SQLite · 本地库
                    仅暴露隧道端口             ~/.claude jsonl 来源
```

家里一台 Mac 跑服务 + 内网穿透,一台云服务器做 TLS 公网入口。仅此而已。

## 🚀 快速开始

```bash
npm install
npm run build              # → dist/ (Web) + dist-server/ (后端)
npm run start              # 服务只监听环回 127.0.0.1:3001

# 暴露公网:frpc 隧道 → 云端 nginx (TLS),浏览器打开 https://cli.example.com:8443/
```

把占位符(`cli.example.com` / `<SERVER_IP>`)换成你自己的子域名与服务器。完整部署见 **[documentation/使用指南.md](documentation/使用指南.md)**,官网落地页见 `docs/index.html`。

> 测试期可用 `DEV_AUTH_BYPASS` 免登录;上线请关闭并启用密码 + TOTP。

## 🧪 开发

```bash
npm run dev          # 后端(tsx)+ vite 前端
npm run typecheck    # 前端 + 后端两个 tsconfig
npm run lint
# 后端测试(需 server tsconfig 解析 @/* 别名):
npx tsx --tsconfig server/tsconfig.json --test "server/**/*.test.ts"
```

## 🙏 致谢

基于 [claudecodeui](https://github.com/siteboon/claudecodeui) 的 Claude-only 分支精简、加固而来(TOTP + FRP 私有部署 + 多端 IM）。
