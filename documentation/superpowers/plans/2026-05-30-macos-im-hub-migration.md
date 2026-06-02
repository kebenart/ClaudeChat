# macOS IM-Hub Migration Plan

> Make the macOS app's conversation list AND chat IM-hub-driven (ImConversationDTO /
> ImMessageDTO with live im:* updates), consistent with iOS/web. macOS already
> shares the IM core (Storage/ImSyncEngine/IMController/DTOs) — this rewires the
> views/AppViewModel to read from it, mirroring iOS's IOSAppModel. 6 stages, each
> independently buildable; provider path stays live until Stage 5.

**Reference to port from:** apple/ios/Sources/{IOSAppModel,ChatDetailView,IOSMessageBubble,ChatListView}.swift
**Verify each stage:** `cd apple && swift build -c debug` green + launch.

## Keep vs Drop (to match iOS's simpler IM chat)
- DROP: inline tool-approval cards, streaming ChatMessage bubbles + ToolBatchView,
  provider send-status popover, server-paged "加载更早". Replace with IM text/result/
  error bubbles + collapsed ToolTraceCard + transcript sheet.
- KEEP: transcript ("查看完整记录", already IM-native), slash picker, image/file
  attachments + drag-drop (macOS stays richer here — forward images/@path through IM send),
  quote, 3-column layout, Rail, Me tab, blacklist, contacts, multi-profile auth/TOTP.

## Stage 1 — expose IM list on AppViewModel (additive, dormant)
- IMController: grow into macOS IM core — add `conversations: [ImConversationDTO]`,
  `refresh()` (sort pinned+lastActivity, prune locallyDeletedIds, unread via engine),
  `messages(_:)`, `markRead`, paged cold sync, consume-style frame handling for
  liveSessionIds/thinking. Port from IOSAppModel.
- AppViewModel: add `imConversations`, `liveSessionIds`, `locallyDeletedIds`,
  `isSyncing`, `lastSyncError`, `foregroundConversationId`; `refreshImList()`.
  connectAndLoad → paged sync + refreshImList + refreshLiveSessions.
- Verify: build green, UI unchanged, imConversations populates.

## Stage 2 — Sidebar list from IM conversations
- SessionListViewModel.refresh accepts [ImConversationDTO]; port retained/visible/
  foldedConvs (3-day retention; keep pinned/live/thinking/unread). Adapter maps
  ImConversationDTO → fields SessionRowView needs (lower risk).
- SidebarView feeds vm.imConversations; chatRow callbacks already IM-based.
- MainWindowView drives listVM from vm.imConversations. currentSessionId == id.
- Keep contacts on provider sessions for now.

## Stage 3 — chat pane on IM messages
- Create ImChatViewModel (analog of ChatDetailView state: messages filtered to
  text/result/error, pending/confirmedPendingIds/claimedServerIds echo, reload from
  storage.imMessages, time dividers).
- Rewrite ChatView to render an IM bubble (port IOSMessageBubble → AppKit copy via
  NSPasteboard, MarkdownSheet, ToolTraceCard via fetchTranscript). Reload on thinking
  transition + liveConv.lastSeq. Keep header/transcript/composer+slash+attachments.
- Leave old MessageBubble.swift unreferenced until Stage 5.

## Stage 4 — send/thinking/live-refresh via IM consume loop
- AppViewModel.sendMessage: keep macOS composition (quote/@path/images) but iOS shape
  (claudeCommand resume:true bypassPermissions images:), thinking insert, optimistic
  echo in ImChatViewModel.pending. Remove ChatMessage optimistic insert + send-status.
- handleServerEvent: port IOSAppModel.consume. DELETE assistantText/toolUse/toolResult
  arms (+ scheduleOpenSessionRefresh/refreshCurrentSessionMessages). Keep complete/
  sessionStatus/error → clear thinking + scheduleSync; notifications from IM result path.

## Stage 5 — remove provider chat/list path (not trivially reversible; gate on green S4)
- Delete ChatViewModel, old MessageBubble tool/approval, ToolBatchView, selectSession
  provider backfill, messageBumpCount, etc. Keep Storage.messages in core if used elsewhere.

## Stage 6 — contacts, new-session, parity polish
- Contacts from api.fetchProjects(); new session via startNewSession(projectPath:firstPrompt:)
  ported from IOSAppModel. NewSessionPopover → IM. pullRefresh/reconnect/badge parity.

## Riskiest coupling
1. currentSessionId/selectSession/sessions referenced everywhere — keep currentSessionId,
   add parallel imConversations so consumers migrate independently.
2. messageBumpCount/ChatViewModel.messages drive whole chat path — highest churn, Stage 3.
3. provider WS arms become dead — surgically cut ChatMessage-writing, keep thinking/sync.
4. Contacts uses provider listSessions — keep or move to fetchProjects (Stage 6).
