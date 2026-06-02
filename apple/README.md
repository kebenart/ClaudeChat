# Apple Native Client

Native macOS + iOS chat client for the `claudecodeui-local` backend. WeChat-aesthetic UI.

## Run

```bash
cd apple
swift build
swift run ClaudeChat
swift test
```

Requires Xcode 16+ / Swift 6+ / macOS 14+.

## Layout

```
apple/
├── Package.swift
├── Sources/
│   ├── ChatKit/                # multiplatform core (macOS + iOS)
│   │   ├── DTOs.swift          # Codable wire types
│   │   ├── Events.swift        # ServerEvent / ClientEvent
│   │   ├── Errors.swift        # ChatKitError
│   │   ├── Protocols.swift     # public layer contracts
│   │   ├── Network/            # Agent A: APIClient, ChatSocket, Keychain, Auth
│   │   ├── Storage/            # Agent B: SwiftData models + reducer
│   │   └── UI/                 # Agent C: SwiftUI views + ViewModels
│   └── ClaudeChat/             # macOS executable entry
└── Tests/ChatKitTests/
```

## V1 deployment notes

The macOS executable currently runs via SPM (`swift run`). This works for dev but:
- No code signing → unsigned binary, Gatekeeper will warn on distribution
- No bundle ID → some system APIs (UNUserNotificationCenter) may behave oddly
- No Info.plist customization → can't set NSApplicationCategoryType etc.

For production .app + notarization + APNs push, wrap with an Xcode project later. iOS target also requires Xcode project (SPM can't produce a launchable iOS app on its own).

## Backend contract

All API + WS routes are defined by the parent repo. See:
- `server/routes/auth.js` — `/api/auth/*`
- `server/modules/projects/projects.routes.ts` — `/api/projects/*`
- `server/routes/sessions.js` — `/api/sessions/*`
- `server/modules/websocket/services/chat-websocket.service.ts` — `/ws` (chat)
- `server/claude-sdk.js` — what kinds of messages the server emits on the WS

The client never modifies backend behavior.
