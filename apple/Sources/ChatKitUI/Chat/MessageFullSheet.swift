import ChatKit
import SwiftUI

// MARK: - MessageFullSheet
//
// Modal sheet that displays a message's full content with proper markdown
// rendering: headings, lists, blockquotes, inline emphasis, and fenced code
// blocks with syntax highlighting. Opened by double-clicking a truncated
// bubble.

/// How the full-message sheet renders the body: parsed markdown vs. raw text.
private enum FullSheetMode: Hashable {
    case markdown
    case plain
}

public struct MessageFullSheet: View {
    let content: String
    let isUser: Bool
    /// True while the full body is still being lazily fetched (server-truncated
    /// message). Shows a small spinner in the title bar until the body lands.
    let loading: Bool
    let onClose: () -> Void

    public init(content: String, isUser: Bool, loading: Bool = false, onClose: @escaping () -> Void) {
        self.content = content
        self.isUser = isUser
        self.loading = loading
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(isUser ? "你的消息" : "Claude 的回复")
                    .font(.system(size: 14, weight: .semibold))
                if loading {
                    ProgressView().controlSize(.small)
                    Text("加载完整内容…").font(.system(size: 11)).foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                // Render mode: parsed markdown preview vs. raw plain text.
                Picker("", selection: $mode) {
                    Text("渲染").tag(FullSheetMode.markdown)
                    Text("纯文本").tag(FullSheetMode.plain)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("在解析后的 Markdown 预览和原始文本之间切换")
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("复制全部")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(AppColors.background)

            Divider()

            // Body — switches between rendered markdown and raw monospace text.
            ScrollView {
                Group {
                    switch mode {
                    case .markdown:
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(parseMarkdownSegments(content).enumerated()), id: \.offset) { _, segment in
                                switch segment {
                                case .text(let t):
                                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownText(raw: t)
                                    }
                                case .code(let lang, let code):
                                    CodeBlockView(language: lang, code: code)
                                }
                            }
                        }
                    case .plain:
                        Text(content)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(AppColors.primaryText)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 580, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }

    @State private var copied = false
    @State private var mode: FullSheetMode = .markdown

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

// MARK: - MarkdownText
//
// Inline / multi-line markdown renderer shared by MessageFullSheet (and
// reusable elsewhere). Handles headings, bullet/numbered lists, blockquotes,
// inline bold/italic/code/links.

struct MarkdownText: View {
    let raw: String

    var body: some View {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                line.isEmpty ? AnyView(Spacer().frame(height: 4)) : AnyView(lineView(line))
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.drop { $0 == " " }
        if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4))))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3))))
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 6)
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2))))
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 8)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2))))
                    .font(.system(size: 13))
            }
        } else if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let marker = String(trimmed[trimmed.startIndex..<m.upperBound]).trimmingCharacters(in: .whitespaces)
            let body = String(trimmed[m.upperBound...])
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).font(.system(size: 13))
                Text(inline(body)).font(.system(size: 13))
            }
        } else if trimmed.hasPrefix("> ") {
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(inline(String(trimmed.dropFirst(2))))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(inline(String(line)))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
