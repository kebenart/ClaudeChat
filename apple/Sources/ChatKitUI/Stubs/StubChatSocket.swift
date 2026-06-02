import ChatKit
import Foundation

// MARK: - StubChatSocket
// TODO: swap to real ChatSocket on integration

public final class StubChatSocket: ChatSocketProtocol, @unchecked Sendable {
    // MARK: ChatSocketProtocol

    public let events: AsyncStream<ServerEvent>

    private let continuation: AsyncStream<ServerEvent>.Continuation
    private var _isConnected: Bool = false
    private let lock = NSLock()

    public var isConnected: Bool {
        get async { lock.withLock { _isConnected } }
    }

    public init() {
        var cont: AsyncStream<ServerEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func connect(baseURL: URL, token: String) async throws {
        lock.withLock { _isConnected = true }
    }

    public func disconnect() async {
        lock.withLock { _isConnected = false }
        continuation.finish()
    }

    public func send(_ event: ClientEvent) async throws {
        // For previews/stubs: echo user messages back as an assistant response
        switch event {
        case let .claudeCommand(prompt, sessionId, _, _, _, _, _, _, _, _, _):
            let sid = sessionId ?? "stub-new-session"
            // Simulate brief typing then response
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                let msgId = "stub-\(UUID().uuidString)"
                continuation.yield(.assistantText(
                    sessionId: sid,
                    messageId: msgId,
                    text: "收到你的消息: 「\(prompt)」。这是来自 StubChatSocket 的模拟回复。",
                    isDelta: false
                ))
                try? await Task.sleep(nanoseconds: 500_000_000)
                continuation.yield(.complete(sessionId: sid, exitCode: 0, aborted: false, isNewSession: false))
            }
        default:
            break
        }
    }

    public func setLatencyHandler(_ handler: @escaping @Sendable (Int) -> Void) async {
        // Stub: hand back a fixed plausible sample so previews show a value.
        handler(8)
    }

    public func ping() async {}

    // MARK: - Test helpers

    /// Inject a scripted event into the stream (for previews/tests).
    public func inject(_ event: ServerEvent) {
        continuation.yield(event)
    }
}
