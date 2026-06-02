import ChatKit
import Foundation

// MARK: - StubServerProfileStore
// TODO: swap to UserDefaults/JSON-backed store on integration

public final class StubServerProfileStore: ServerProfileStoreProtocol, @unchecked Sendable {
    private var profiles: [ServerProfile]
    private let lock = NSLock()

    public init() {
        profiles = [
            ServerProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                url: URL(string: "http://localhost:3000")!,
                displayName: "本地开发",
                username: "admin",
                lastUsedAt: Date()
            )
        ]
    }

    public func list() -> [ServerProfile] {
        lock.withLock { profiles }
    }

    public func upsert(_ profile: ServerProfile) {
        lock.withLock {
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
        }
    }

    public func remove(_ profileId: UUID) {
        lock.withLock { profiles.removeAll { $0.id == profileId } }
    }

    public func mostRecent() -> ServerProfile? {
        lock.withLock {
            profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt })
        }
    }
}
