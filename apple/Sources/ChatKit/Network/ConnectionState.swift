import Foundation

/// Health of the chat WebSocket, surfaced to every platform's UI.
public enum ConnectionState: Sendable, Equatable {
    case online                       // connected + heartbeat healthy
    case reconnecting(attempt: Int)   // lost the server, auto-retry in progress
    case offline                      // device has no network path (NWPathMonitor)
    case failed                       // gave up after the auto-retry cap — needs a manual reconnect
}
