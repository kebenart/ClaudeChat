import Foundation

/// Persists the list of `ServerProfile` values in `UserDefaults` as a JSON blob
/// under the key `chatkit.serverProfiles`.
public final class ServerProfileStore: ServerProfileStoreProtocol, @unchecked Sendable {
    private let defaultsKey = "chatkit.serverProfiles"
    private let defaults: UserDefaults
    private let lock = NSLock()

    // Shared encoder/decoder with ISO-8601 dates.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - ServerProfileStoreProtocol

    public func list() -> [ServerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return _load()
    }

    public func upsert(_ profile: ServerProfile) {
        lock.lock()
        defer { lock.unlock() }
        var profiles = _load()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        _save(profiles)
    }

    public func remove(_ profileId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var profiles = _load()
        profiles.removeAll { $0.id == profileId }
        _save(profiles)
    }

    public func mostRecent() -> ServerProfile? {
        lock.lock()
        defer { lock.unlock() }
        return _load().sorted { $0.lastUsedAt > $1.lastUsedAt }.first
    }

    // MARK: - Private

    private func _load() -> [ServerProfile] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? decoder.decode([ServerProfile].self, from: data)) ?? []
    }

    private func _save(_ profiles: [ServerProfile]) {
        if let data = try? encoder.encode(profiles) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
