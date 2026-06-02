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
