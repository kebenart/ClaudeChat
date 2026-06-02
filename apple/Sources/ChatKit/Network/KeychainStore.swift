import Foundation
import Security

/// Persists bearer tokens in the system Keychain.
///
/// Service identifier: `com.claudecodeui.macclient.token`
/// Account identifier: the profile UUID string.
public final class KeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private let service = "com.claudecodeui.macclient.token"

    public init() {}

    // MARK: - KeychainStoreProtocol

    public func token(for profileId: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileId.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    public func setToken(_ token: String?, for profileId: UUID) {
        if let token {
            _upsert(token: token, profileId: profileId)
        } else {
            _delete(profileId: profileId)
        }
    }

    // MARK: - Private helpers

    private func _upsert(token: String, profileId: UUID) {
        guard let data = token.data(using: .utf8) else { return }
        let account = profileId.uuidString

        // Try update first.
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let updateAttributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it.
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                // macOS: allow background access without UI prompt.
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func _delete(profileId: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileId.uuidString,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
