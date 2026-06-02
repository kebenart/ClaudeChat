import XCTest
@testable import ChatKit
@testable import ChatKitUI

final class UITextTruncationTests: XCTestCase {

    // MARK: - MessageTextTier (single boundary at 500 chars)

    func testShortBelow500() {
        let text = String(repeating: "a", count: 499)
        XCTAssertEqual(MessageTextTier.tier(for: text), .short)
    }

    func testExactly500IsTruncated() {
        let text = String(repeating: "b", count: 500)
        XCTAssertEqual(MessageTextTier.tier(for: text), .truncated)
    }

    func testLongTextIsTruncated() {
        XCTAssertEqual(MessageTextTier.tier(for: String(repeating: "c", count: 5000)), .truncated)
    }

    func testEmptyIsShort() {
        XCTAssertEqual(MessageTextTier.tier(for: ""), .short)
    }

    func testBoundaryAt499() {
        XCTAssertEqual(MessageTextTier.tier(for: String(repeating: "g", count: 499)), .short)
    }

    func testBoundaryAt500() {
        XCTAssertEqual(MessageTextTier.tier(for: String(repeating: "h", count: 500)), .truncated)
    }

    // MARK: - parseMarkdownSegments

    func testNoCodeFenceProducesSingleTextSegment() {
        let segments = parseMarkdownSegments("Hello, world!")
        XCTAssertEqual(segments.count, 1)
        if case .text(let t) = segments[0] {
            XCTAssertEqual(t, "Hello, world!")
        } else {
            XCTFail("Expected .text segment")
        }
    }

    func testSingleCodeFenceProducesThreeSegments() {
        let md = "Before\n```swift\nlet x = 1\n```\nAfter"
        let segments = parseMarkdownSegments(md)
        // text + code + text
        XCTAssertEqual(segments.count, 3)
        if case .code(let lang, let code) = segments[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1")
        } else {
            XCTFail("Expected .code segment at index 1")
        }
    }

    func testCodeFenceWithNoLanguage() {
        let md = "```\necho hello\n```"
        let segments = parseMarkdownSegments(md)
        // Only a code segment (no leading/trailing text)
        let codeSegments = segments.compactMap { seg -> (String?, String)? in
            if case .code(let l, let c) = seg { return (l, c) }
            return nil
        }
        XCTAssertEqual(codeSegments.count, 1)
        XCTAssertNil(codeSegments[0].0)  // no language
        XCTAssertEqual(codeSegments[0].1, "echo hello")
    }

    func testMultipleCodeFences() {
        let md = "A\n```py\nprint(1)\n```\nB\n```js\nconsole.log(2)\n```\nC"
        let segments = parseMarkdownSegments(md)
        let codes = segments.filter { if case .code = $0 { return true }; return false }
        XCTAssertEqual(codes.count, 2)
    }
}
