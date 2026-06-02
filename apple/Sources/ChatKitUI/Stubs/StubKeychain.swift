import ChatKit
import Foundation

// MARK: - StubKeychain
// TODO: swap to real KeychainStore on integration

public final class StubKeychain: KeychainStoreProtocol, @unchecked Sendable {
    private var store: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func token(for profileId: UUID) -> String? {
        lock.withLock { store[profileId] }
    }

    public func setToken(_ token: String?, for profileId: UUID) {
        lock.withLock {
            if let token { store[profileId] = token }
            else { store.removeValue(forKey: profileId) }
        }
    }
}
