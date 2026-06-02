import Foundation
import Network

/// URLSessionWebSocketTask-backed implementation of `ChatSocketProtocol`.
///
/// - Exposes server frames as `AsyncStream<ServerEvent>`.
/// - Reconnects with exponential back-off (1, 2, 4, 8, 16, 30 s cap) on
///   unexpected disconnects.
/// - All mutable state is protected by the `actor` keyword (Swift 6 concurrency).
public actor ChatSocket: ChatSocketProtocol {

    // MARK: - Types

    private enum State {
        case disconnected
        case connecting
        case connected(URLSessionWebSocketTask)
    }

    // MARK: - State

    private var state: State = .disconnected
    private var baseURL: URL?
    private var token: String?

    // Back-off state
    private var reconnectAttempt: Int = 0
    private static let backoffSequence: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Stop auto-retrying after this many consecutive failures and surface
    /// `.failed` — the user must then trigger `reconnect()` manually. Prevents an
    /// endless loop hammering a server/VPN that's actively refusing us.
    private static let maxReconnectAttempts = 3

    // AsyncStream continuation
    private var continuation: AsyncStream<ServerEvent>.Continuation?

    // Heartbeat watchdog — catches "half-dead" servers whose socket never
    // cleanly closes (frames just stop). We ping every 25s; if no inbound
    // frame (incl. our own pong) lands within 35s, force a reconnect.
    private var lastInbound = Date()
    private var heartbeatTask: Task<Void, Never>?

    // Latency probe — timestamp of the ping currently awaiting a pong, plus a
    // handler the owner (AppViewModel / IOSAppModel) sets to receive samples.
    private var pendingPingAt: Date?
    private var latencyHandler: (@Sendable (Int) -> Void)?

    // Device-level reachability. When the path drops we surface `.offline` and,
    // once it returns, kick a fresh connect immediately.
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var deviceOffline = false

    // MARK: - Public surface

    public let events: AsyncStream<ServerEvent>

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Register a callback invoked with each ping→pong round-trip sample (ms).
    public func setLatencyHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        latencyHandler = handler
    }

    /// Fire an immediate ping to refresh the latency reading on demand. No-op
    /// when the socket isn't connected.
    public func ping() async {
        guard case let .connected(task) = state else { return }
        pendingPingAt = Date()
        try? await task.send(.string("{\"type\":\"ping\"}"))
    }

    // MARK: - Init

    public init() {
        var cont: AsyncStream<ServerEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: - ChatSocketProtocol

    public func connect(baseURL: URL, token: String) async throws {
        self.baseURL = baseURL
        self.token = token
        self.reconnectAttempt = 0
        _startPathMonitor()
        try await _connect()
    }

    /// Force a fresh connection reusing the stored baseURL/token. Used when the
    /// app returns to the foreground — iOS suspends the WebSocket in the
    /// background and the task comes back half-open (state still `.connected`,
    /// `send` succeeds locally but frames never leave). Reconnecting on the SAME
    /// AsyncStream (we never `finish()` the continuation) keeps the existing
    /// consumer wired up.
    public func reconnect() async throws {
        guard baseURL != nil, token != nil else {
            throw ChatKitError.websocketDisconnected
        }
        reconnectAttempt = 0
        try await _connect()
    }

    public func send(_ event: ClientEvent) async throws {
        guard case let .connected(task) = state else {
            NSLog("[ChatSocket] send refused — state != .connected")
            throw ChatKitError.websocketDisconnected
        }
        let payload = event.wirePayload()
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            throw ChatKitError.websocketProtocol(message: "Failed to encode client event")
        }
        do {
            try await task.send(.string(string))
        } catch {
            // The underlying URLSessionWebSocketTask threw — most likely the
            // socket died but our `state` still says `.connected` because the
            // receive-loop hadn't run yet. Mark disconnected and rethrow so the
            // caller can show a real error rather than silently retrying on a
            // zombie task next time.
            NSLog("[ChatSocket] send failed: \(error.localizedDescription); marking disconnected")
            state = .disconnected
            throw error
        }
    }

    public func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        _cancelTask(code: .normalClosure, reason: nil)
        state = .disconnected
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal connect / reconnect

    private func _connect() async throws {
        guard let baseURL, let token else {
            throw ChatKitError.websocketDisconnected
        }
        // Cancel any prior task before opening a new one. Without this a stale
        // task can keep its receive loop alive (still delivering broadcasts, so
        // the socket *looks* connected) while `send` goes to a newer half-open
        // task — the message silently never reaches the server.
        _cancelTask(code: .goingAway, reason: nil)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        state = .connecting

        // Build WebSocket URL from HTTP/HTTPS base: ws:// or wss://
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        switch components.scheme {
        case "http":  components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: break
        }
        // Append the WebSocket path used by the backend. The chat WS lives at
        // `/ws` per `server/modules/websocket/services/websocket-server.service.ts`.
        // Agent A originally wrote `/socket` which made every connection
        // attempt fail handshake — symptom was "WebSocket 发送失败" on every
        // send because state never became `.connected`.
        //
        // Idempotency: callers can pass either `http://host` or already-finalised
        // `ws://host/ws`. If the path already ends in `/ws` we do NOT append
        // again — appending `/ws` twice ("/ws/ws") was breaking every WS upgrade
        // in DEV_AUTH_BYPASS because AppViewModel.wsURL(from:) also adds `/ws`.
        let currentPath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        if currentPath.hasSuffix("/ws") {
            components.path = currentPath
        } else {
            components.path = currentPath + "/ws"
        }

        guard let wsURL = components.url else {
            throw ChatKitError.unsupportedURL(baseURL)
        }

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Some WS servers accept token as a query param — add both.
        if var comps2 = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) {
            comps2.queryItems = [URLQueryItem(name: "token", value: token)]
            request.url = comps2.url ?? wsURL
        }

        let task = URLSession.shared.webSocketTask(with: request)
        state = .connected(task)
        task.resume()
        NSLog("[ChatSocket] connected to \(wsURL.absoluteString)")

        // Surface the healthy state and (re)arm the heartbeat watchdog.
        lastInbound = Date()
        continuation?.yield(.connection(.online))
        _startHeartbeat()

        // Start the receive loop in a detached task so the actor isn't blocked.
        Task { [weak self] in
            await self?._receiveLoop(task: task)
        }
    }

    /// Heartbeat watchdog: ping every 25s; if no inbound frame (incl. our own
    /// pong) has landed within 35s, treat the socket as dead and reconnect.
    private func _startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self else { return }
                await self._heartbeatTick()
            }
        }
    }

    private func _heartbeatTick() async {
        guard case .connected(let task) = state else { return }
        if Date().timeIntervalSince(lastInbound) > 35 {
            state = .disconnected
            task.cancel(with: .goingAway, reason: nil)
            await _scheduleReconnect()
        } else {
            pendingPingAt = Date()
            try? await task.send(.string("{\"type\":\"ping\"}"))
        }
    }

    /// Idempotently start the device-reachability monitor. Surfaces `.offline`
    /// when no network path is available and reconnects when one returns.
    private func _startPathMonitor() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Only the Sendable Bool crosses into the actor — never the NWPath.
            let satisfied = (path.status == .satisfied)
            Task { await self?._onPath(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "chatsocket.path"))
    }

    private func _onPath(satisfied: Bool) async {
        if !satisfied, !deviceOffline {
            deviceOffline = true
            continuation?.yield(.connection(.offline))
        } else if satisfied, deviceOffline {
            deviceOffline = false
            // A brief path blip (watchOS hops WiFi↔BT↔LTE constantly) often does
            // NOT actually kill the socket. Don't tear down a still-live task —
            // just restore the UI; only rebuild when it genuinely dropped.
            if case .connected = state {
                continuation?.yield(.connection(.online))
            } else {
                try? await _connect()
            }
        }
    }

    private func _receiveLoop(task: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    _dispatch(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        _dispatch(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                // If a reconnect already swapped in a newer task, this loop is
                // superseded — stay silent so we don't clobber the live state.
                if case let .connected(current) = state, current !== task {
                    return
                }

                // Socket closed — determine if we should reconnect.
                let isNormalClose: Bool
                if let wsError = error as? URLError {
                    isNormalClose = wsError.code == .cancelled
                } else {
                    // URLSessionWebSocketTask throws NSError on close frames too.
                    let code = (error as NSError).code
                    isNormalClose = (code == 57 /* ENOTCONN */ || code == 54 /* ECONNRESET */)
                }

                if isNormalClose {
                    // Intentional disconnect; don't reconnect.
                    state = .disconnected
                    NSLog("[ChatSocket] receive loop ended (normal close)")
                    break
                }

                // Mark disconnected so subsequent `send` calls fail fast with
                // the correct error rather than handing data to a zombie task
                // whose underlying URLSessionWebSocketTask already errored.
                state = .disconnected
                NSLog("[ChatSocket] receive loop error: \(error.localizedDescription) — scheduling reconnect")

                // Emit a transient error but attempt reconnect.
                continuation?.yield(.error(sessionId: nil, message: "WebSocket disconnected: \(error.localizedDescription)"))
                await _scheduleReconnect()
                return
            }
        }
    }

    private func _dispatch(text: String) {
        // Any inbound frame proves the link is alive — feed the heartbeat watchdog.
        lastInbound = Date()
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            continuation?.yield(.raw(kind: nil, type: nil, payload: text.data(using: .utf8) ?? Data()))
            return
        }
        // Pong is a heartbeat ack only — don't surface it as a `.raw` event.
        // It doubles as the latency probe: report the ping→pong round-trip.
        if (json["type"] as? String) == "pong" {
            if let sent = pendingPingAt {
                let ms = Int(Date().timeIntervalSince(sent) * 1000)
                pendingPingAt = nil
                latencyHandler?(max(0, ms))
            }
            return
        }
        let event = ServerEvent.decode(from: json, rawData: data)
        continuation?.yield(event)
    }

    private func _scheduleReconnect() async {
        // Give up after the cap — surface `.failed` and wait for a manual
        // reconnect() (which resets the counter). No more endless retry loop.
        if reconnectAttempt >= Self.maxReconnectAttempts {
            continuation?.yield(.connection(.failed))
            return
        }
        let delay = Self.backoffSequence[min(reconnectAttempt, Self.backoffSequence.count - 1)]
        reconnectAttempt += 1
        continuation?.yield(.connection(.reconnecting(attempt: reconnectAttempt)))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        // Only reconnect if we're still supposed to be connected.
        guard baseURL != nil, token != nil else { return }
        try? await _connect()
    }

    private func _cancelTask(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if case let .connected(task) = state {
            task.cancel(with: code, reason: reason)
        }
    }
}
