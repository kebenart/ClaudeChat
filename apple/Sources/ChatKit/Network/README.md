# Network layer (Agent A)

Files to create:
- `APIClient.swift` — `APIClientProtocol` impl, URLSession + Bearer injection, JSON encoding/decoding
- `ChatSocket.swift` — `ChatSocketProtocol` impl, URLSessionWebSocketTask + reconnect/backoff
- `KeychainStore.swift` — `KeychainStoreProtocol` impl, SecItem*
- `ServerProfileStore.swift` — `ServerProfileStoreProtocol` impl, UserDefaults JSON
- `AuthCoordinator.swift` — coordinates login → TOTP flow, persists token to Keychain
- `Network+JSON.swift` — shared decoders (ISO-8601 dates, snake_case strategy if needed)

Tests in `Tests/ChatKitTests/Network*Tests.swift` using `URLProtocol` mocks.
