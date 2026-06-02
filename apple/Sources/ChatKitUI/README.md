# UI layer (Agent C)

Files to create:
- `Theme/Colors.swift` — light + dark palettes, WeChat-ish (#ededed bg, #95ec69 user bubble, #ffffff claude bubble)
- `Theme/AppFont.swift` — font size environment value backed by `@AppStorage("chatFontSize")` — small/medium/large/xl mapping to 12/13/15/17pt
- `Avatar/AvatarHashing.swift` — `avatarColor(for sessionId:)` (12-color palette, stable hash), `avatarText(for title:)` (first CJK char else first ASCII letter)
- `Auth/LoginView.swift`, `Auth/TOTPView.swift`, `Auth/ServerPickerView.swift`
- `Sidebar/RailView.swift` (far-left dark strip), `Sidebar/SidebarView.swift` (search + list + new-chat button), `Sidebar/SessionRowView.swift` (avatar + title + preview + red dot)
- `Chat/ChatView.swift`, `Chat/MessageBubble.swift`, `Chat/ToolCard.swift` (pending + executed states), `Chat/FileCard.swift`, `Chat/DetailPanel.swift` (slide-in), `Chat/ComposerView.swift`
- `Settings/SettingsView.swift` (font size, auto-approve switch, server list, logout)
- `ViewModels/AppViewModel.swift` (top-level: current server, auth state), `ViewModels/SessionListViewModel.swift`, `ViewModels/ChatViewModel.swift`
- `AppSettings.swift` — @AppStorage wrappers: `chatFontSize`, `autoApproveAll`

Until Agents A/B land, ViewModels can use in-memory stub stores so UI compiles + previews work.
