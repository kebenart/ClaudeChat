import ChatKit
import SwiftUI

// MARK: - CodeBlockView

/// Renders a fenced code block: gray background, monospaced font,
/// horizontal scroll, vertical scroll capped at 220pt.
public struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var isCopied = false

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: language label + copy button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang.lowercased())
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                Button(action: copyCode) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()
                .background(AppColors.lightBorder)

            // Code content. The inner Text uses fixedSize(horizontal:true) so only
            // the CONTENT overflows horizontally — the ScrollView itself stays
            // width-bounded. Without this, a horizontal ScrollView whose content
            // wants infinite width + an outer height-only constraint can make the
            // layout solver fail to converge (15s main-thread hang). Mirrors the
            // iOS MarkdownText.codeBlock fix.
            ScrollView([.horizontal, .vertical]) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(AppFont.codeBlock)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
        }
        .background(AppColors.codeBackground, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppColors.lightBorder, lineWidth: 0.5))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        isCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            isCopied = false
        }
    }
}

// MARK: - Markdown Code Extraction

/// Split markdown text into segments: plain text vs code blocks.
enum ContentSegment {
    case text(String)
    case code(language: String?, content: String)
}

func parseMarkdownSegments(_ raw: String) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var remaining = raw
    let pattern = "```([^\\n]*)\\n([\\s\\S]*?)```"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return [.text(raw)]
    }
    var lastEnd = remaining.startIndex
    let nsRange = NSRange(remaining.startIndex..., in: remaining)
    let matches = regex.matches(in: remaining, range: nsRange)
    for match in matches {
        // Text before this match
        if let r = Range(match.range(at: 0), in: remaining) {
            let beforeRange = lastEnd..<r.lowerBound
            let before = String(remaining[beforeRange])
            if !before.isEmpty { segments.append(.text(before)) }

            // Language (capture group 1)
            var lang: String? = nil
            if let langRange = Range(match.range(at: 1), in: remaining) {
                let l = String(remaining[langRange]).trimmingCharacters(in: .whitespaces)
                if !l.isEmpty { lang = l }
            }
            // Code content (capture group 2)
            if let codeRange = Range(match.range(at: 2), in: remaining) {
                let code = String(remaining[codeRange])
                    .trimmingCharacters(in: .newlines)
                segments.append(.code(language: lang, content: code))
            }
            lastEnd = r.upperBound
        }
    }
    // Remaining text
    let tail = String(remaining[lastEnd...])
    if !tail.isEmpty { segments.append(.text(tail)) }
    return segments
}
