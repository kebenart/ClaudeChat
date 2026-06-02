import ChatKit
import SwiftUI

// MARK: - FileCard

/// Displays very long content (> 5000 chars or file content) as a WeChat-style card.
/// Tapping opens the DetailPanel slide-in.
public struct FileCard: View {
    let title: String
    let content: String
    let meta: String?
    var onTap: (() -> Void)?

    public init(title: String, content: String, meta: String? = nil, onTap: (() -> Void)? = nil) {
        self.title = title
        self.content = content
        self.meta = meta
        self.onTap = onTap
    }

    private var lineCount: Int { content.components(separatedBy: "\n").count }
    private var sizeKB: Double { Double(content.utf8.count) / 1024 }

    public var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    // File icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppColors.cardIconBackground)
                            .frame(width: 36, height: 36)
                        Image(systemName: "doc.text")
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.actionText)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let meta { Text(meta).foregroundStyle(AppColors.secondaryText) }
                            Text("·").foregroundStyle(AppColors.tertiaryText)
                            Text("\(lineCount) 行 · \(String(format: "%.1f", sizeKB)) KB")
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .font(.system(size: 11))
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .background(AppColors.cardDivider)

                HStack {
                    Text("由 Claude 生成 · \(timeLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                    Spacer()
                    Text("点击查看 →")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.actionText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppColors.lightBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
