# Storage layer (Agent B)

Files to create:
- `StorageModels.swift` — SwiftData `@Model` classes: `SessionRecord`, `MessageRecord`
- `Storage.swift` — actor conforming to `StorageProtocol`, owns a `ModelContainer`
- `StorageContainer.swift` — `ModelContainer` factory (on-disk default + in-memory for tests)
- `EventReducer.swift` — consumes `AsyncStream<ServerEvent>`, mutates Storage; emits per-event side effects (unread, notifications) via a callback

Tests in `Tests/ChatKitTests/Storage*Tests.swift` using in-memory `ModelContainer`.
