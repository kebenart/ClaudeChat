import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class UIAvatarHashingTests: XCTestCase {

    // MARK: - color(for:)

    func testColorIsDeterministicForSameSeed() {
        let c1 = AvatarHashing.color(for: "session-abc")
        let c2 = AvatarHashing.color(for: "session-abc")
        XCTAssertEqual(c1, c2, "Same seed should always produce the same color")
    }

    func testColorDiffersForDifferentSeeds() {
        // With 12 colors and distinct seeds the first few are very likely different
        let seeds = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta",
                     "eta", "theta", "iota", "kappa", "lambda", "mu"]
        let colors = seeds.map { AvatarHashing.color(for: $0) }
        // At least 2 of the 12 must differ (they span the whole palette)
        let unique = Set(colors.map { "\($0)" })
        XCTAssertGreaterThan(unique.count, 1)
    }

    func testColorForEmptySeedDoesNotCrash() {
        let c = AvatarHashing.color(for: "")
        // Just ensure we get a Color back without crashing
        _ = c
    }

    func testColorStabilityAcrossCallsWithUnicodeSeeds() {
        let seed = "会话-\u{4E2D}\u{6587}"
        let c1 = AvatarHashing.color(for: seed)
        let c2 = AvatarHashing.color(for: seed)
        XCTAssertEqual(c1, c2)
    }

    // MARK: - text(for:)

    func testTextForCJKTitle() {
        XCTAssertEqual(AvatarHashing.text(for: "写 macOS 客户端"), "写")
        XCTAssertEqual(AvatarHashing.text(for: "回测策略"),         "回")
        XCTAssertEqual(AvatarHashing.text(for: "疏影横斜"),         "疏")
    }

    func testTextForCJKTitleWithLeadingSpaces() {
        XCTAssertEqual(AvatarHashing.text(for: " 写 macOS"), "写")
    }

    func testTextForASCIITitle() {
        XCTAssertEqual(AvatarHashing.text(for: "Hello"),      "H")
        XCTAssertEqual(AvatarHashing.text(for: "myProject"),  "M")
        XCTAssertEqual(AvatarHashing.text(for: "abc"),        "A")
    }

    func testTextForMixedLeadingNumberThenLetter() {
        // Leading digit, then a letter
        XCTAssertEqual(AvatarHashing.text(for: "123abc"), "A")
    }

    func testTextForEmptyTitle() {
        XCTAssertEqual(AvatarHashing.text(for: ""), "?")
    }

    func testTextForDigitsOnly() {
        // No letters — fallback to "?"
        XCTAssertEqual(AvatarHashing.text(for: "12345"), "?")
    }

    func testTextForSingleCharCJK() {
        XCTAssertEqual(AvatarHashing.text(for: "星"), "星")
    }

    func testTextIsDeterministic() {
        let t1 = AvatarHashing.text(for: "Hello World")
        let t2 = AvatarHashing.text(for: "Hello World")
        XCTAssertEqual(t1, t2)
    }
}
