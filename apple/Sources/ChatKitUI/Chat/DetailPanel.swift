import ChatKit
import SwiftUI

// MARK: - DetailPanel

/// Slide-in panel from the right showing full file/long content with line numbers.
public struct DetailPanel: View {
    let title: String
    let content: String
    var onClose: () -> Void

    @State private var isCopied = false

    public init(title: String, content: String, onClose: @escaping () -> Void) {
        self.title = title
        self.content = content
        self.onClose = onClose
    }

    private var lines: [String] { content.components(separatedBy: "\n") }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(AppColors.secondaryText)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                // Copy button
                Button(action: copyAll) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("复制全部内容")

                // Save button
                Button(action: saveFile) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("保存到文件")

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content with line numbers
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(idx + 1)")
                                .font(AppFont.lineNumber)
                                .foregroundStyle(AppColors.lineNumber)
                                .frame(width: 32, alignment: .trailing)
                                .padding(.trailing, 8)
                                .userInteractionDisabled()

                            Text(line.isEmpty ? " " : line)
                                .font(AppFont.codeBlock)
                                .foregroundStyle(AppColors.primaryText)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(AppColors.detailPanel)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppColors.border)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: -4, y: 0)
    }

    // MARK: - Actions

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        isCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            isCopied = false
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - View helper

extension View {
    func userInteractionDisabled() -> some View {
        self.allowsHitTesting(false)
    }
}
