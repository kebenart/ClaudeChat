import XCTest
@testable import ChatKit
@testable import ChatKitUI

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
