import SwiftUI
import ChatKit

/// Sheet showing the raw full-record transcript for a conversation.
/// Loads the first 40 entries; scrolling up loads older entries via the anchor.
struct TranscriptSheet: View {
    let conversation: ImConversationDTO
    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ImTranscriptEntry] = []
    @State private var hasMoreBefore: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var isLoading: Bool = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    ContentUnavailableView("暂无记录", systemImage: "doc.text")
                } else {
                    List {
                        // Load-more at the top
                        if hasMoreBefore {
                            Button {
                                Task { await loadOlder() }
                            } label: {
                                if isLoadingMore {
                                    HStack {
                                        ProgressView()
                                        Text("加载更多…")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                } else {
                                    Text("加载更旧记录")
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .foregroundStyle(.blue)
                                }
                            }
                            .disabled(isLoadingMore)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(renderItems) { item in
                            switch item.kind {
                            case .entry(let entry):
                                entryRow(entry)
                            case .toolGroup(let group):
                                DisclosureGroup {
                                    ForEach(group) { entryRow($0) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .imageScale(.small)
                                            .foregroundStyle(.secondary)
                                        Text("执行了 \(group.count) 个操作")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("完整记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            await loadInitial()
        }
    }

    // MARK: - Folding model

    private enum RenderKind {
        case entry(ImTranscriptEntry)
        case toolGroup([ImTranscriptEntry])
    }
    private struct RenderItem: Identifiable {
        let id: String
        let kind: RenderKind
    }
    private static let foldable: Set<String> = ["tool_use", "tool_result", "thinking"]

    /// Collapse consecutive tool/thinking entries into a foldable group and drop
    /// empty `meta` plumbing rows — same treatment as the web client.
    private var renderItems: [RenderItem] {
        var items: [RenderItem] = []
        var run: [ImTranscriptEntry] = []
        func flush() {
            if let first = run.first {
                items.append(RenderItem(id: "tg-\(first.id)", kind: .toolGroup(run)))
            }
            run = []
        }
        for e in entries {
            if e.kind == "meta", e.summary.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let k = e.kind, Self.foldable.contains(k) {
                run.append(e)
            } else {
                flush()
                items.append(RenderItem(id: e.id, kind: .entry(e)))
            }
        }
        flush()
        return items
    }

    // MARK: - Row

    @ViewBuilder private func entryRow(_ entry: ImTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: entry.type))
                    .foregroundStyle(typeColor(for: entry.type))
                    .imageScale(.small)
                Text(entry.type)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(typeColor(for: entry.type))
                Spacer()
                if entry.hasBlob {
                    Label("大内容已截断", systemImage: "ellipsis.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "text": return "text.bubble"
        case "tool_use": return "wrench.and.screwdriver"
        case "tool_result": return "checkmark.circle"
        case "thinking": return "brain"
        case "error": return "exclamationmark.triangle"
        default: return "doc.text"
        }
    }

    private func typeColor(for type: String) -> Color {
        switch type {
        case "text": return .primary
        case "tool_use": return .blue
        case "tool_result": return .green
        case "thinking": return .purple
        case "error": return .red
        default: return .secondary
        }
    }

    // MARK: - Loading

    private func loadInitial() async {
        isLoading = true
        let page = await model.fetchTranscript(conversationId: conversation.id)
        entries = page.entries
        hasMoreBefore = page.hasMoreBefore
        isLoading = false
    }

    private func loadOlder() async {
        guard let firstId = entries.first?.id, !isLoadingMore else { return }
        isLoadingMore = true
        let page = await model.fetchTranscript(conversationId: conversation.id, anchor: firstId)
        entries = page.entries + entries
        hasMoreBefore = page.hasMoreBefore
        isLoadingMore = false
    }
}
