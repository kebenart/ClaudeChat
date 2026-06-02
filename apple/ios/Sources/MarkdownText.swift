import SwiftUI

// MARK: - MarkdownText
//
// A pragmatic block-level markdown renderer for chat bubbles. SwiftUI's
// `Text(AttributedString(markdown:))` only handles inline syntax; this splits
// the content into fenced code blocks vs prose, renders code in a monospaced
// scrollable box, and applies inline markdown (bold / italic / `code` / links)
// to everything else while preserving line breaks.

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.resolved(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code, let lang):
                    codeBlock(code, lang: lang)
                case .attributed(let text):
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Parse cache
    //
    // `AttributedString(markdown:)` and the block split are expensive and were
    // re-run on EVERY body evaluation — every re-render (streaming, sync, scroll)
    // re-parsed every visible bubble, which is the chat-view jank. Message
    // content is immutable, so parse once per unique string and cache the fully
    // resolved blocks (prose already turned into AttributedString).

    private enum Resolved {
        case attributed(AttributedString)
        case code(String, lang: String?)
    }

    private static let cache = NSCache<NSString, ResolvedBox>()
    private final class ResolvedBox { let blocks: [Resolved]; init(_ b: [Resolved]) { blocks = b } }

    private static func resolved(_ content: String) -> [Resolved] {
        let key = content as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(content).map { block -> Resolved in
            switch block {
            case .text(let t): return .attributed(inline(t))
            case .code(let c, let lang): return .code(c, lang: lang)
            }
        }
        cache.setObject(ResolvedBox(blocks), forKey: key)
        return blocks
    }

    @ViewBuilder private func codeBlock(_ code: String, lang: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lang, !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // The horizontal ScrollView's intrinsic width is unbounded; nesting it
            // inside a vertical chat row that ALSO asked for maxWidth:.infinity made
            // SwiftUI's layout solver fail to converge on certain content (long
            // code lines in a non-folded bubble) → the main thread spun forever and
            // the whole app froze. Pinning the ScrollView to the available width
            // (and letting only its CONTENT overflow) breaks that cycle.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Parsing

    private enum Block {
        case text(String)
        case code(String, lang: String?)
    }

    /// Split on ``` fences. Everything between a pair of fences is a code block;
    /// the rest is prose. Unterminated fences fold the remainder into code.
    private static func parse(_ content: String) -> [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var lang: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(.text(joined)) }
            prose = []
        }
        func flushCode() {
            result.append(.code(code.joined(separator: "\n"), lang: lang))
            code = []; lang = nil
        }

        for line in content.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode(); inCode = false
                } else {
                    flushProse(); inCode = true
                    lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return result
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
