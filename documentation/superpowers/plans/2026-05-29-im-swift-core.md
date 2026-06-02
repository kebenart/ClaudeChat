# Swift IM Core Implementation Plan (子系统 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `apple/` 的 ChatKit 库中实现 macOS+iOS 共享的 IM 核心 —— 本地优先 SwiftData 镜像 + 同步引擎(applySync/applyFrame/computeUnread)+ IM REST 方法 + `im:*` WS 帧解码,严格对齐服务端线上契约。**不含 UI**(UI 是子系统 3/4)。

**Architecture:** 新增与服务端 wire 完全一致的 Codable DTO;新增三个 `@Model`(ImConversationRecord / ImMessageRecord / ImReadCursorRecord)+ 一个游标记录,挂进 `StorageContainer` schema;`Storage` actor 加 IM 读写方法;`ServerEvent` 加 `imMessage/imRead/imPoke` 三个 case 并在 `decode` 解析;新增 `ImSyncEngine` actor(消费 sync 响应与 im: 帧、算未读);`APIClient` 加 IM 端点。所有逻辑用 XCTest + 内存 `Storage` + `MockURLProtocol` 测。

**Tech Stack:** Swift 6.1,SwiftData,SwiftPM(`swift test`),XCTest。严格并发(actor 守护可变态,DTO 为 Sendable 值类型)。

> **契约对齐**:Swift 端的 DTO 必须与服务端 `serializeMessage` / `routes/im.js` / `im-events.service.ts` 字段逐一对应,并与 Web 端 `src/services/im/protocol.ts` 一致。**单用户跨端已读**:`unread = max(0, lastSeq − maxReadSeqAcrossDevices)`。

---

## 服务端契约(本计划消费,来自子系统 1)

```
WireMessage      { id:String; conversationId:String; seq:Int; role:String; kind:String;
                   content:String; createdAt:Int(epoch ms); toolTrace?:{count:Int; rawRefStart:String; rawRefEnd:String} }
WireConversation { id:String; contactId:String?; providerId:String; title:String?;
                   lastMessagePreview:String?; lastSeq:Int; lastActivityAt:Int; isPinned:Bool; isMuted:Bool }
WireReadCursor   { conversationId:String; deviceId:String; lastReadSeq:Int }
SyncResponse     { messages:[WireMessage]; conversations:[WireConversation]; readCursors:[WireReadCursor]; cursor:Int; hasMore:Bool }
GET  /api/im/sync?since=<rev>
GET  /api/im/conversations/:id/messages?anchor=&numBefore=&numAfter=  -> { messages:[WireMessage] }
POST /api/im/conversations/:id/read   body { deviceId, lastReadSeq }
POST /api/im/conversations/:id/state  body { isPinned?, isMuted? }
WS frames on /ws: im:message {message}, im:read {conversationId,deviceId,lastReadSeq}, im:poke {since}
```

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `apple/Sources/ChatKit/IM/ImDTOs.swift` | wire Codable DTO(ImMessageDTO/ImConversationDTO/ImReadCursorDTO/ImSyncResponse/ImToolTrace) | Create |
| `apple/Sources/ChatKit/IM/ImModels.swift` | `@Model` 记录:ImConversationRecord/ImMessageRecord/ImReadCursorRecord/ImSyncStateRecord | Create |
| `apple/Sources/ChatKit/Storage/StorageContainer.swift` | schema 加入 4 个 IM @Model | Modify |
| `apple/Sources/ChatKit/IM/ImStorage.swift` | `Storage` 的 IM 扩展(upsert/list/readCursor/syncCursor) | Create |
| `apple/Sources/ChatKit/Events.swift` | `ServerEvent` 加 imMessage/imRead/imPoke + decode 分支 | Modify |
| `apple/Sources/ChatKit/IM/ImSyncEngine.swift` | applySync / applyFrame / computeUnread | Create |
| `apple/Sources/ChatKit/Network/APIClient.swift` | IM REST 方法 | Modify |
| `apple/Sources/ChatKit/Protocols.swift` | APIClientProtocol 加 IM 方法签名 | Modify |
| `apple/Sources/ChatKit/IM/DeviceIdentity.swift` | 持久化每安装 deviceId(UserDefaults) | Create |
| `apple/Tests/ChatKitTests/Im*Tests.swift` | 对应单测 | Create |

IM 代码集中在新目录 `Sources/ChatKit/IM/`,与既有 provider-session 模型(SessionRecord/MessageRecord)并存、互不影响。

---

## Task 1: IM wire DTOs

**Files:**
- Create: `apple/Sources/ChatKit/IM/ImDTOs.swift`
- Test: `apple/Tests/ChatKitTests/ImDTOsTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/ImDTOsTests.swift`**

```swift
import XCTest
@testable import ChatKit

final class ImDTOsTests: XCTestCase {
    func testDecodeSyncResponseWithToolTrace() throws {
        let json = """
        {
          "messages": [
            {"id":"s1","conversationId":"c1","seq":1,"role":"user","kind":"text","content":"hi","createdAt":10},
            {"id":"a1","conversationId":"c1","seq":2,"role":"assistant","kind":"result","content":"yo","createdAt":20,
             "toolTrace":{"count":2,"rawRefStart":"x","rawRefEnd":"y"}}
          ],
          "conversations": [
            {"id":"c1","contactId":"/r","providerId":"claude","title":"C1","lastMessagePreview":"yo",
             "lastSeq":2,"lastActivityAt":20,"isPinned":false,"isMuted":false}
          ],
          "readCursors": [{"conversationId":"c1","deviceId":"devA","lastReadSeq":1}],
          "cursor": 2,
          "hasMore": false
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(ImSyncResponse.self, from: json)
        XCTAssertEqual(resp.cursor, 2)
        XCTAssertFalse(resp.hasMore)
        XCTAssertEqual(resp.messages.count, 2)
        XCTAssertNil(resp.messages[0].toolTrace)
        XCTAssertEqual(resp.messages[1].toolTrace?.count, 2)
        XCTAssertEqual(resp.messages[1].toolTrace?.rawRefEnd, "y")
        XCTAssertEqual(resp.conversations[0].lastSeq, 2)
        XCTAssertEqual(resp.readCursors[0].deviceId, "devA")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter ImDTOsTests`
Expected: FAIL — `ImSyncResponse` 未定义。

- [ ] **Step 3: 实现 `apple/Sources/ChatKit/IM/ImDTOs.swift`**

```swift
import Foundation

/// Folded tool activity for the gray collapsed bar. `count` = number of tool
/// operations (tool_use blocks). rawRef* span the raw jsonl entry id range of
/// the turn's tool activity, for the "view full record" viewer.
public struct ImToolTrace: Codable, Hashable, Sendable {
    public let count: Int
    public let rawRefStart: String
    public let rawRefEnd: String

    public init(count: Int, rawRefStart: String, rawRefEnd: String) {
        self.count = count
        self.rawRefStart = rawRefStart
        self.rawRefEnd = rawRefEnd
    }
}

public struct ImMessageDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let conversationId: String
    public let seq: Int
    public let role: String
    public let kind: String
    public let content: String
    public let createdAt: Int   // epoch milliseconds
    public let toolTrace: ImToolTrace?

    public init(id: String, conversationId: String, seq: Int, role: String, kind: String,
                content: String, createdAt: Int, toolTrace: ImToolTrace? = nil) {
        self.id = id; self.conversationId = conversationId; self.seq = seq
        self.role = role; self.kind = kind; self.content = content
        self.createdAt = createdAt; self.toolTrace = toolTrace
    }
}

public struct ImConversationDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let contactId: String?
    public let providerId: String
    public let title: String?
    public let lastMessagePreview: String?
    public let lastSeq: Int
    public let lastActivityAt: Int
    public let isPinned: Bool
    public let isMuted: Bool

    public init(id: String, contactId: String?, providerId: String, title: String?,
                lastMessagePreview: String?, lastSeq: Int, lastActivityAt: Int,
                isPinned: Bool, isMuted: Bool) {
        self.id = id; self.contactId = contactId; self.providerId = providerId
        self.title = title; self.lastMessagePreview = lastMessagePreview
        self.lastSeq = lastSeq; self.lastActivityAt = lastActivityAt
        self.isPinned = isPinned; self.isMuted = isMuted
    }
}

public struct ImReadCursorDTO: Codable, Hashable, Sendable {
    public let conversationId: String
    public let deviceId: String
    public let lastReadSeq: Int

    public init(conversationId: String, deviceId: String, lastReadSeq: Int) {
        self.conversationId = conversationId; self.deviceId = deviceId; self.lastReadSeq = lastReadSeq
    }
}

public struct ImSyncResponse: Codable, Sendable {
    public let messages: [ImMessageDTO]
    public let conversations: [ImConversationDTO]
    public let readCursors: [ImReadCursorDTO]
    public let cursor: Int
    public let hasMore: Bool
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apple && swift test --filter ImDTOsTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add apple/Sources/ChatKit/IM/ImDTOs.swift apple/Tests/ChatKitTests/ImDTOsTests.swift
git commit -m "feat(im-swift): wire-contract DTOs (conversation/message/readcursor/sync)"
```

---

## Task 2: IM SwiftData models + schema + Storage methods

**Files:**
- Create: `apple/Sources/ChatKit/IM/ImModels.swift`
- Modify: `apple/Sources/ChatKit/Storage/StorageContainer.swift:17-19`
- Create: `apple/Sources/ChatKit/IM/ImStorage.swift`
- Test: `apple/Tests/ChatKitTests/ImStorageTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/ImStorageTests.swift`**

```swift
import XCTest
@testable import ChatKit

final class ImStorageTests: XCTestCase {
    private func makeStorage() throws -> Storage {
        Storage(container: try StorageContainer.makeInMemory())
    }

    func testUpsertMessagesIsIdempotentAndOrdersBySeq() async throws {
        let storage = try makeStorage()
        await storage.upsertImConversation(ImConversationDTO(
            id: "c1", contactId: "/r", providerId: "claude", title: "C1",
            lastMessagePreview: "yo", lastSeq: 2, lastActivityAt: 20, isPinned: false, isMuted: false))
        await storage.upsertImMessages([
            ImMessageDTO(id: "s1", conversationId: "c1", seq: 1, role: "user", kind: "text", content: "hi", createdAt: 10),
            ImMessageDTO(id: "s2", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "yo", createdAt: 20),
        ])
        // Re-upsert s2 with grown content (streaming) — updates in place.
        await storage.upsertImMessages([
            ImMessageDTO(id: "s2", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "yo more", createdAt: 21),
        ])

        let msgs = await storage.imMessages(conversationId: "c1")
        XCTAssertEqual(msgs.map(\.seq), [1, 2])
        XCTAssertEqual(msgs[1].content, "yo more")
        XCTAssertEqual(await storage.imConversations().count, 1)
    }

    func testReadCursorUsesMaxAndSyncCursorRoundTrips() async throws {
        let storage = try makeStorage()
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devA", lastReadSeq: 3)
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devA", lastReadSeq: 1) // lower ignored
        await storage.setImReadCursor(conversationId: "c1", deviceId: "devB", lastReadSeq: 5)
        let cursors = await storage.imReadCursors()
        XCTAssertEqual(cursors.first(where: { $0.deviceId == "devA" })?.lastReadSeq, 3)
        XCTAssertEqual(cursors.count, 2)

        XCTAssertEqual(await storage.imSyncCursor(), 0)
        await storage.setImSyncCursor(42)
        XCTAssertEqual(await storage.imSyncCursor(), 42)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter ImStorageTests`
Expected: FAIL — `upsertImConversation` 未定义。

- [ ] **Step 3: 实现 `apple/Sources/ChatKit/IM/ImModels.swift`**

```swift
import Foundation
import SwiftData

@Model public final class ImConversationRecord {
    @Attribute(.unique) public var id: String
    public var contactId: String?
    public var providerId: String
    public var title: String?
    public var lastMessagePreview: String?
    public var lastSeq: Int
    public var lastActivityAt: Int
    public var isPinned: Bool
    public var isMuted: Bool

    public init(id: String, contactId: String?, providerId: String, title: String?,
                lastMessagePreview: String?, lastSeq: Int, lastActivityAt: Int,
                isPinned: Bool, isMuted: Bool) {
        self.id = id; self.contactId = contactId; self.providerId = providerId
        self.title = title; self.lastMessagePreview = lastMessagePreview
        self.lastSeq = lastSeq; self.lastActivityAt = lastActivityAt
        self.isPinned = isPinned; self.isMuted = isMuted
    }
}

@Model public final class ImMessageRecord {
    @Attribute(.unique) public var id: String
    public var conversationId: String
    public var seq: Int
    public var role: String
    public var kind: String
    public var content: String
    public var createdAt: Int
    public var toolTraceCount: Int
    public var rawRefStart: String?
    public var rawRefEnd: String?

    public init(id: String, conversationId: String, seq: Int, role: String, kind: String,
                content: String, createdAt: Int, toolTraceCount: Int,
                rawRefStart: String?, rawRefEnd: String?) {
        self.id = id; self.conversationId = conversationId; self.seq = seq
        self.role = role; self.kind = kind; self.content = content; self.createdAt = createdAt
        self.toolTraceCount = toolTraceCount; self.rawRefStart = rawRefStart; self.rawRefEnd = rawRefEnd
    }
}

@Model public final class ImReadCursorRecord {
    /// Composite key flattened: "<conversationId>\t<deviceId>".
    @Attribute(.unique) public var id: String
    public var conversationId: String
    public var deviceId: String
    public var lastReadSeq: Int

    public init(conversationId: String, deviceId: String, lastReadSeq: Int) {
        self.id = "\(conversationId)\t\(deviceId)"
        self.conversationId = conversationId; self.deviceId = deviceId; self.lastReadSeq = lastReadSeq
    }
}

@Model public final class ImSyncStateRecord {
    @Attribute(.unique) public var id: String  // always "cursor"
    public var cursor: Int
    public init(cursor: Int) { self.id = "cursor"; self.cursor = cursor }
}
```

- [ ] **Step 4: schema 加入新 @Model** —— 在 `apple/Sources/ChatKit/Storage/StorageContainer.swift` 的 `makeSchema()`:

```swift
    private static func makeSchema() -> Schema {
        Schema([
            SessionRecord.self, MessageRecord.self,
            ImConversationRecord.self, ImMessageRecord.self,
            ImReadCursorRecord.self, ImSyncStateRecord.self,
        ])
    }
```

- [ ] **Step 5: 实现 `apple/Sources/ChatKit/IM/ImStorage.swift`**

```swift
import Foundation
import SwiftData

// IM extensions on the existing Storage actor. Mirror the wire model; the
// distilled IM data is separate from the provider SessionRecord/MessageRecord.
extension Storage {
    public func upsertImConversation(_ c: ImConversationDTO) {
        let ctx = modelContext
        let id = c.id
        let existing = try? ctx.fetch(FetchDescriptor<ImConversationRecord>(
            predicate: #Predicate { $0.id == id })).first
        if let r = existing {
            r.contactId = c.contactId; r.providerId = c.providerId; r.title = c.title
            r.lastMessagePreview = c.lastMessagePreview; r.lastSeq = c.lastSeq
            r.lastActivityAt = c.lastActivityAt; r.isPinned = c.isPinned; r.isMuted = c.isMuted
        } else {
            ctx.insert(ImConversationRecord(
                id: c.id, contactId: c.contactId, providerId: c.providerId, title: c.title,
                lastMessagePreview: c.lastMessagePreview, lastSeq: c.lastSeq,
                lastActivityAt: c.lastActivityAt, isPinned: c.isPinned, isMuted: c.isMuted))
        }
        try? ctx.save()
    }

    public func upsertImMessages(_ messages: [ImMessageDTO]) {
        let ctx = modelContext
        for m in messages {
            let id = m.id
            let existing = try? ctx.fetch(FetchDescriptor<ImMessageRecord>(
                predicate: #Predicate { $0.id == id })).first
            if let r = existing {
                r.seq = m.seq; r.role = m.role; r.kind = m.kind; r.content = m.content
                r.createdAt = m.createdAt; r.toolTraceCount = m.toolTrace?.count ?? 0
                r.rawRefStart = m.toolTrace?.rawRefStart; r.rawRefEnd = m.toolTrace?.rawRefEnd
            } else {
                ctx.insert(ImMessageRecord(
                    id: m.id, conversationId: m.conversationId, seq: m.seq, role: m.role,
                    kind: m.kind, content: m.content, createdAt: m.createdAt,
                    toolTraceCount: m.toolTrace?.count ?? 0,
                    rawRefStart: m.toolTrace?.rawRefStart, rawRefEnd: m.toolTrace?.rawRefEnd))
            }
        }
        try? ctx.save()
    }

    public func imConversations() -> [ImConversationDTO] {
        let ctx = modelContext
        let rows = (try? ctx.fetch(FetchDescriptor<ImConversationRecord>())) ?? []
        return rows.map { r in
            ImConversationDTO(id: r.id, contactId: r.contactId, providerId: r.providerId,
                              title: r.title, lastMessagePreview: r.lastMessagePreview,
                              lastSeq: r.lastSeq, lastActivityAt: r.lastActivityAt,
                              isPinned: r.isPinned, isMuted: r.isMuted)
        }
    }

    public func imMessages(conversationId: String) -> [ImMessageDTO] {
        let ctx = modelContext
        let cid = conversationId
        let rows = (try? ctx.fetch(FetchDescriptor<ImMessageRecord>(
            predicate: #Predicate { $0.conversationId == cid },
            sortBy: [SortDescriptor(\.seq, order: .forward)]))) ?? []
        return rows.map { r in
            let trace: ImToolTrace? = (r.toolTraceCount > 0 && r.rawRefStart != nil && r.rawRefEnd != nil)
                ? ImToolTrace(count: r.toolTraceCount, rawRefStart: r.rawRefStart!, rawRefEnd: r.rawRefEnd!)
                : nil
            return ImMessageDTO(id: r.id, conversationId: r.conversationId, seq: r.seq, role: r.role,
                                kind: r.kind, content: r.content, createdAt: r.createdAt, toolTrace: trace)
        }
    }

    public func setImReadCursor(conversationId: String, deviceId: String, lastReadSeq: Int) {
        let ctx = modelContext
        let key = "\(conversationId)\t\(deviceId)"
        let existing = try? ctx.fetch(FetchDescriptor<ImReadCursorRecord>(
            predicate: #Predicate { $0.id == key })).first
        if let r = existing {
            r.lastReadSeq = max(r.lastReadSeq, lastReadSeq)
        } else {
            ctx.insert(ImReadCursorRecord(conversationId: conversationId, deviceId: deviceId, lastReadSeq: lastReadSeq))
        }
        try? ctx.save()
    }

    public func imReadCursors() -> [ImReadCursorDTO] {
        let ctx = modelContext
        let rows = (try? ctx.fetch(FetchDescriptor<ImReadCursorRecord>())) ?? []
        return rows.map { ImReadCursorDTO(conversationId: $0.conversationId, deviceId: $0.deviceId, lastReadSeq: $0.lastReadSeq) }
    }

    public func imSyncCursor() -> Int {
        let ctx = modelContext
        return (try? ctx.fetch(FetchDescriptor<ImSyncStateRecord>())).flatMap { $0.first?.cursor } ?? 0
    }

    public func setImSyncCursor(_ cursor: Int) {
        let ctx = modelContext
        if let r = try? ctx.fetch(FetchDescriptor<ImSyncStateRecord>()).first {
            r.cursor = cursor
        } else {
            ctx.insert(ImSyncStateRecord(cursor: cursor))
        }
        try? ctx.save()
    }
}
```

> **校验**:打开 `apple/Sources/ChatKit/Storage/Storage.swift` 确认 `Storage` 是 `actor` 且有可用的 `modelContext`(或等价的内部 `ModelContext` 属性名)。若访问器名称不同(如 `context`),将上面所有 `modelContext` 替换为真实名。若 `ModelContext` 不在 actor 上而是每次新建,沿用该文件既有 upsert 方法的写法(模仿 `upsertMessage`)。

- [ ] **Step 6: 运行确认通过**

Run: `cd apple && swift test --filter ImStorageTests`
Expected: PASS(2 用例)

- [ ] **Step 7: 提交**

```bash
git add apple/Sources/ChatKit/IM/ImModels.swift apple/Sources/ChatKit/IM/ImStorage.swift apple/Sources/ChatKit/Storage/StorageContainer.swift apple/Tests/ChatKitTests/ImStorageTests.swift
git commit -m "feat(im-swift): SwiftData IM models + Storage upsert/read-cursor/sync-cursor"
```

---

## Task 3: ServerEvent im: cases + decode

**Files:**
- Modify: `apple/Sources/ChatKit/Events.swift`
- Test: `apple/Tests/ChatKitTests/ImEventsTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/ImEventsTests.swift`**

```swift
import XCTest
@testable import ChatKit

final class ImEventsTests: XCTestCase {
    private func decode(_ s: String) -> ServerEvent {
        let data = s.data(using: .utf8)!
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ServerEvent.decode(from: json, rawData: data)
    }

    func testDecodeImMessage() {
        let ev = decode("""
        {"type":"im:message","message":{"id":"a1","conversationId":"c1","seq":2,"role":"assistant","kind":"result","content":"done","createdAt":9}}
        """)
        guard case let .imMessage(conversationId, message) = ev else { return XCTFail("expected imMessage, got \(ev)") }
        XCTAssertEqual(conversationId, "c1")
        XCTAssertEqual(message.id, "a1")
        XCTAssertEqual(message.seq, 2)
        XCTAssertEqual(message.content, "done")
    }

    func testDecodeImRead() {
        let ev = decode("""
        {"type":"im:read","conversationId":"c1","deviceId":"phone","lastReadSeq":7}
        """)
        guard case let .imRead(conversationId, deviceId, lastReadSeq) = ev else { return XCTFail("expected imRead") }
        XCTAssertEqual(conversationId, "c1")
        XCTAssertEqual(deviceId, "phone")
        XCTAssertEqual(lastReadSeq, 7)
    }

    func testDecodeImPoke() {
        let ev = decode("""{"type":"im:poke","since":42}""")
        guard case let .imPoke(since) = ev else { return XCTFail("expected imPoke") }
        XCTAssertEqual(since, 42)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter ImEventsTests`
Expected: FAIL — `.imMessage` case 不存在。

- [ ] **Step 3: 在 `Events.swift` 的 `ServerEvent` enum 增加三个 case**(放在 `case raw(...)` 之前):

```swift
    case imMessage(conversationId: String, message: ImMessageDTO)
    case imRead(conversationId: String, deviceId: String, lastReadSeq: Int)
    case imPoke(since: Int)
```

- [ ] **Step 4: 在 `ServerEvent.decode(from:rawData:)` 的 switch 增加分支**(在 `default: return .raw(...)` 之前)。注意 `im:message` 的 `message` 字段需用 `JSONDecoder` 从 rawData 中取出嵌套对象:

```swift
        case "im:message":
            let convId = json["conversationId"] as? String
                ?? (json["message"] as? [String: Any])?["conversationId"] as? String ?? ""
            if let msgObj = json["message"],
               let msgData = try? JSONSerialization.data(withJSONObject: msgObj),
               let dto = try? JSONDecoder().decode(ImMessageDTO.self, from: msgData) {
                return .imMessage(conversationId: convId.isEmpty ? dto.conversationId : convId, message: dto)
            }
            return .raw(kind: kind, type: type_, payload: rawData)
        case "im:read":
            return .imRead(
                conversationId: json["conversationId"] as? String ?? "",
                deviceId: json["deviceId"] as? String ?? "",
                lastReadSeq: json["lastReadSeq"] as? Int ?? 0)
        case "im:poke":
            return .imPoke(since: json["since"] as? Int ?? 0)
```

> **校验**:打开 `Events.swift:189-288` 确认 `decode` 里实际的变量名(map 入参 `json`、`kind`、`type_`、`rawData`)与本片段一致;若不同,按真实名调整。

- [ ] **Step 5: 运行确认通过**

Run: `cd apple && swift test --filter ImEventsTests`
Expected: PASS(3 用例)

- [ ] **Step 6: 提交**

```bash
git add apple/Sources/ChatKit/Events.swift apple/Tests/ChatKitTests/ImEventsTests.swift
git commit -m "feat(im-swift): decode im:message/im:read/im:poke server events"
```

---

## Task 4: ImSyncEngine(applySync / applyFrame / computeUnread)

**Files:**
- Create: `apple/Sources/ChatKit/IM/ImSyncEngine.swift`
- Test: `apple/Tests/ChatKitTests/ImSyncEngineTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/ImSyncEngineTests.swift`**

```swift
import XCTest
@testable import ChatKit

final class ImSyncEngineTests: XCTestCase {
    private func makeStorage() throws -> Storage {
        Storage(container: try StorageContainer.makeInMemory())
    }

    func testApplySyncPersistsAndSetsCursor() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        let resp = ImSyncResponse(
            messages: [ImMessageDTO(id: "s1", conversationId: "c1", seq: 1, role: "user", kind: "text", content: "hi", createdAt: 1)],
            conversations: [ImConversationDTO(id: "c1", contactId: nil, providerId: "claude", title: "C1",
                lastMessagePreview: "hi", lastSeq: 1, lastActivityAt: 1, isPinned: false, isMuted: false)],
            readCursors: [ImReadCursorDTO(conversationId: "c1", deviceId: "devA", lastReadSeq: 0)],
            cursor: 5, hasMore: false)
        await engine.applySync(resp)
        XCTAssertEqual(await storage.imSyncCursor(), 5)
        XCTAssertEqual(await storage.imMessages(conversationId: "c1").count, 1)
    }

    func testComputeUnreadUsesMaxReadAcrossDevices() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 5, lastActivityAt: 1, isPinned: false, isMuted: false))
        await storage.setImReadCursor(conversationId: "c1", deviceId: "phone", lastReadSeq: 5)
        await storage.setImReadCursor(conversationId: "c1", deviceId: "desktop", lastReadSeq: 2)
        let unread = await engine.computeUnread()
        XCTAssertEqual(unread["c1"], 0) // read on phone (max=5) clears everywhere
    }

    func testApplyFrameImMessageBumpsConversation() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 1, lastActivityAt: 1, isPinned: false, isMuted: false))
        await engine.applyFrame(.imMessage(conversationId: "c1",
            message: ImMessageDTO(id: "a1", conversationId: "c1", seq: 2, role: "assistant", kind: "result", content: "done", createdAt: 9)))
        let conv = await storage.imConversations().first { $0.id == "c1" }
        XCTAssertEqual(conv?.lastSeq, 2)
        XCTAssertEqual(conv?.lastMessagePreview, "done")
        XCTAssertEqual(await engine.computeUnread()["c1"], 2)
    }

    func testApplyFrameImReadClearsUnread() async throws {
        let storage = try makeStorage()
        let engine = ImSyncEngine(storage: storage)
        await storage.upsertImConversation(ImConversationDTO(id: "c1", contactId: nil, providerId: "claude",
            title: "C1", lastMessagePreview: "", lastSeq: 3, lastActivityAt: 1, isPinned: false, isMuted: false))
        XCTAssertEqual(await engine.computeUnread()["c1"], 3)
        await engine.applyFrame(.imRead(conversationId: "c1", deviceId: "phone", lastReadSeq: 3))
        XCTAssertEqual(await engine.computeUnread()["c1"], 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter ImSyncEngineTests`
Expected: FAIL — `ImSyncEngine` 未定义。

- [ ] **Step 3: 实现 `apple/Sources/ChatKit/IM/ImSyncEngine.swift`**

```swift
import Foundation

/// Local-first IM sync engine. Folds /sync responses and im:* frames into the
/// Storage actor, and computes per-conversation unread.
public actor ImSyncEngine {
    private let storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }

    /// Apply a full or incremental /sync response.
    public func applySync(_ resp: ImSyncResponse) async {
        if !resp.conversations.isEmpty {
            for c in resp.conversations { await storage.upsertImConversation(c) }
        }
        if !resp.messages.isEmpty {
            await storage.upsertImMessages(resp.messages)
        }
        for rc in resp.readCursors {
            await storage.setImReadCursor(conversationId: rc.conversationId, deviceId: rc.deviceId, lastReadSeq: rc.lastReadSeq)
        }
        await storage.setImSyncCursor(resp.cursor)
    }

    /// Apply one incoming im:* server event. Returns true if it carried data
    /// (im:poke returns false — the caller decides whether to re-sync).
    @discardableResult
    public func applyFrame(_ event: ServerEvent) async -> Bool {
        switch event {
        case let .imMessage(conversationId, message):
            await storage.upsertImMessages([message])
            // Keep the conversation's lastSeq/preview in step with the newest message.
            if let conv = await storage.imConversations().first(where: { $0.id == conversationId }),
               message.seq >= conv.lastSeq {
                await storage.upsertImConversation(ImConversationDTO(
                    id: conv.id, contactId: conv.contactId, providerId: conv.providerId, title: conv.title,
                    lastMessagePreview: String(message.content.prefix(120)),
                    lastSeq: message.seq, lastActivityAt: message.createdAt,
                    isPinned: conv.isPinned, isMuted: conv.isMuted))
            }
            return true
        case let .imRead(conversationId, deviceId, lastReadSeq):
            await storage.setImReadCursor(conversationId: conversationId, deviceId: deviceId, lastReadSeq: lastReadSeq)
            return true
        default:
            return false
        }
    }

    /// Per-conversation unread = max(0, lastSeq - maxReadSeqAcrossDevices).
    /// Single-user: reading on any device (the max cursor) clears the dot everywhere.
    public func computeUnread() async -> [String: Int] {
        let conversations = await storage.imConversations()
        let cursors = await storage.imReadCursors()
        var maxRead: [String: Int] = [:]
        for c in cursors {
            maxRead[c.conversationId] = max(maxRead[c.conversationId] ?? 0, c.lastReadSeq)
        }
        var unread: [String: Int] = [:]
        for conv in conversations {
            unread[conv.id] = max(0, conv.lastSeq - (maxRead[conv.id] ?? 0))
        }
        return unread
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apple && swift test --filter ImSyncEngineTests`
Expected: PASS(4 用例)

- [ ] **Step 5: 提交**

```bash
git add apple/Sources/ChatKit/IM/ImSyncEngine.swift apple/Tests/ChatKitTests/ImSyncEngineTests.swift
git commit -m "feat(im-swift): ImSyncEngine applySync/applyFrame/computeUnread"
```

---

## Task 5: APIClient IM REST 方法

**Files:**
- Modify: `apple/Sources/ChatKit/Network/APIClient.swift`
- Modify: `apple/Sources/ChatKit/Protocols.swift`(APIClientProtocol 加签名)
- Test: `apple/Tests/ChatKitTests/ImAPIClientTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/ImAPIClientTests.swift`**

复用既有 `NetworkAPIClientTests` 的 `MockURLProtocol` 模式。若 `MockURLProtocol` 不是公开可复用,在本文件内重新定义一个同样的最小版本(见 `NetworkAPIClientTests.swift:5-44`)。

```swift
import XCTest
@testable import ChatKit

final class ImAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IMMockURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://test.local")!, session: URLSession(configuration: config))
    }

    func testFetchImSyncParsesResponseAndSendsCursor() async throws {
        let client = makeClient()
        await client.setToken("jwt-abc")
        IMMockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.path, "/api/im/sync")
            XCTAssertTrue(req.url?.query?.contains("since=7") ?? false)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-abc")
            let body = """
            {"messages":[],"conversations":[],"readCursors":[],"cursor":9,"hasMore":false}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        let resp = try await client.fetchImSync(since: 7)
        XCTAssertEqual(resp.cursor, 9)
    }

    func testPostImReadSendsDeviceAndSeq() async throws {
        let client = makeClient()
        IMMockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/im/conversations/c1/read")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, #"{"ok":true}"#.data(using: .utf8)!)
        }
        try await client.postImRead(conversationId: "c1", deviceId: "devA", lastReadSeq: 3)
    }
}

final class IMMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = IMMockURLProtocol.requestHandler else { return }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
```

> **校验**:若既有 `MockURLProtocol` 已是 `@testable` 可见且可复用,直接复用它、删掉本文件的 `IMMockURLProtocol`,避免重复注册冲突。两者不要同时对同一 `URLSession` 注册。

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter ImAPIClientTests`
Expected: FAIL — `fetchImSync` 未定义。

- [ ] **Step 3: APIClientProtocol 加签名**(`apple/Sources/ChatKit/Protocols.swift` 的 `APIClientProtocol`):

```swift
    func fetchImSync(since: Int) async throws -> ImSyncResponse
    func fetchImMessages(conversationId: String, anchor: Int?, numBefore: Int, numAfter: Int) async throws -> [ImMessageDTO]
    func postImRead(conversationId: String, deviceId: String, lastReadSeq: Int) async throws
    func postImState(conversationId: String, isPinned: Bool?, isMuted: Bool?) async throws
```

- [ ] **Step 4: 在 `APIClient.swift` 实现这些方法**。复用文件里已有的 `buildRequest` / `perform` 私有方法(见 APIClient.swift:455-485);若签名不同,按真实辅助函数改写。下面假设有 `func perform<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T` 与 `baseURL`/`token`:

```swift
    public func fetchImSync(since: Int) async throws -> ImSyncResponse {
        try await perform("/api/im/sync?since=\(since)")
    }

    public func fetchImMessages(conversationId: String, anchor: Int?, numBefore: Int, numAfter: Int) async throws -> [ImMessageDTO] {
        var path = "/api/im/conversations/\(conversationId)/messages?numBefore=\(numBefore)&numAfter=\(numAfter)"
        if let anchor { path += "&anchor=\(anchor)" }
        struct Wrapper: Decodable { let messages: [ImMessageDTO] }
        let w: Wrapper = try await perform(path)
        return w.messages
    }

    public func postImRead(conversationId: String, deviceId: String, lastReadSeq: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "lastReadSeq": lastReadSeq])
        let _: EmptyResponse = try await perform("/api/im/conversations/\(conversationId)/read", method: "POST", body: body)
    }

    public func postImState(conversationId: String, isPinned: Bool?, isMuted: Bool?) async throws {
        var obj: [String: Any] = [:]
        if let isPinned { obj["isPinned"] = isPinned }
        if let isMuted { obj["isMuted"] = isMuted }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let _: EmptyResponse = try await perform("/api/im/conversations/\(conversationId)/state", method: "POST", body: body)
    }
```

且在文件内(若不存在)加一个用于无 body 响应解码的小类型:

```swift
    struct EmptyResponse: Decodable {}
```

> **校验**:`perform` 的真实签名/路径拼接方式以 APIClient.swift 现有实现为准。关键不变量:GET `/api/im/sync?since=`、POST `/api/im/conversations/:id/read` 带 `{deviceId,lastReadSeq}`、Bearer token 由现有 `buildRequest` 注入。`conversationId` 用于路径时若可能含特殊字符,按文件既有方式做 percent-encoding。

- [ ] **Step 5: 运行确认通过**

Run: `cd apple && swift test --filter ImAPIClientTests`
Expected: PASS(2 用例)

- [ ] **Step 6: 提交**

```bash
git add apple/Sources/ChatKit/Network/APIClient.swift apple/Sources/ChatKit/Protocols.swift apple/Tests/ChatKitTests/ImAPIClientTests.swift
git commit -m "feat(im-swift): APIClient IM endpoints (sync/messages/read/state)"
```

---

## Task 6: DeviceIdentity(持久 deviceId)

**Files:**
- Create: `apple/Sources/ChatKit/IM/DeviceIdentity.swift`
- Test: `apple/Tests/ChatKitTests/DeviceIdentityTests.swift`

- [ ] **Step 1: 写失败测试 `apple/Tests/ChatKitTests/DeviceIdentityTests.swift`**

```swift
import XCTest
@testable import ChatKit

final class DeviceIdentityTests: XCTestCase {
    func testReturnsStableIdAcrossCalls() {
        let defaults = UserDefaults(suiteName: "im-device-test-\(UUID().uuidString)")!
        let a = DeviceIdentity.current(defaults: defaults)
        let b = DeviceIdentity.current(defaults: defaults)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b) // persisted, stable
    }

    func testDistinctSuitesGetDistinctIds() {
        let d1 = UserDefaults(suiteName: "im-device-test-\(UUID().uuidString)")!
        let d2 = UserDefaults(suiteName: "im-device-test-\(UUID().uuidString)")!
        XCTAssertNotEqual(DeviceIdentity.current(defaults: d1), DeviceIdentity.current(defaults: d2))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apple && swift test --filter DeviceIdentityTests`
Expected: FAIL — `DeviceIdentity` 未定义。

- [ ] **Step 3: 实现 `apple/Sources/ChatKit/IM/DeviceIdentity.swift`**

```swift
import Foundation

/// Stable per-installation device id used for IM read cursors. Persisted in
/// UserDefaults (per app sandbox). Injectable for tests.
public enum DeviceIdentity {
    private static let key = "im.device.id"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apple && swift test --filter DeviceIdentityTests`
Expected: PASS(2 用例)

- [ ] **Step 5: 全量测试 + 提交**

```bash
cd apple && swift test
```
Expected: 既有 + 新增 IM 测试全部 PASS。

```bash
git add apple/Sources/ChatKit/IM/DeviceIdentity.swift apple/Tests/ChatKitTests/DeviceIdentityTests.swift
git commit -m "feat(im-swift): persistent per-install device identity"
```

---

## Self-Review

**Spec coverage(对照地基 spec §12 各端落地 + §7/§8/§11):**
- 本地优先 SwiftData 镜像 → Task 2 (@Model + Storage) ✅
- IM 数据模型(Conversation/Message/ReadCursor + toolTrace)→ Task 1 (DTO) + Task 2 (records) ✅
- 同步协议(/sync rev 游标、messages、read、state)→ Task 5 (APIClient) ✅
- WS 帧 im:message/im:read/im:poke → Task 3 (decode) ✅
- 同步引擎(applySync/applyFrame)+ 跨端未读(max read across devices)→ Task 4 ✅
- deviceId → Task 6 ✅
- 共享(macOS+iOS):全部在 ChatKit 库(平台 `.macOS(.v14)/.iOS(.v17)`),无 AppKit/UIKit 依赖 ✅
- 发送消息:沿用既有 chat WS 路径(子系统 1 说明),本核心不新造发送 → 不在本计划(同 Web 端) ✅

**Placeholder scan:** 每个代码步骤为完整 Swift 代码 + 测试。三处"校验"标注(Storage 的 modelContext 访问器名、Events.decode 变量名、APIClient 的 perform/MockURLProtocol 复用)是对既有代码的接入校验并给了确切定位与替代写法,非占位。

**Type consistency:** `ImMessageDTO`/`ImConversationDTO`/`ImReadCursorDTO`/`ImSyncResponse`(Task 1)贯穿 Task 2(Storage)/ Task 4(engine)/ Task 5(API);`ServerEvent.imMessage/.imRead/.imPoke`(Task 3)被 Task 4 `applyFrame` 消费;`computeUnread` 返回 `[String:Int]`。字段名与服务端 wire + Web 端 protocol.ts 一致(createdAt 为 epoch ms Int)。

**已知后续(非本计划):** socket.events → ImSyncEngine 的接线、初始/增量 sync 触发、与 ViewModel/UI 的对接属于子系统 3/4;im:poke 触发再同步的调度也在那层。

---

## Execution Handoff

见下方对话 —— 给出执行方式选择。
