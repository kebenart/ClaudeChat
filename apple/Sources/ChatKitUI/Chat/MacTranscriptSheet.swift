import ChatKit
import SwiftUI

// MARK: - MacTranscriptSheet
//
// "查看完整记录" — the raw, un-distilled session transcript (tools / thinking /
// results the IM chat stream hides). Loads the latest page; scroll up loads
// older. Consecutive tool/thinking entries fold into a "执行了 N 个操作"
// disclosure; empty plumbing rows are dropped. Mirrors the iOS TranscriptSheet.

struct MacTranscriptSheet: View {
    let sessionId: String
    let title: String

    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ImTranscriptEntry] = []
    @State private var hasMoreBefore = false
    @State private var isLoading = true
    @State private var isLoadingMore = false

    private static let foldable: Set<String> = ["tool_use", "tool_result", "thinking"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 560, height: 640)
        .background(AppColors.background)
        .task { await loadInitial() }
    }

    private var header: some View {
        HStack {
            Text("完整记录 · \(title)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.primaryText)
                .lineLimit(1)
            Spacer()
            Button("关闭") { dismiss() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("暂无记录")
                .foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if hasMoreBefore {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            HStack {
                                if isLoadingMore { ProgressView().controlSize(.small) }
                                Text(isLoadingMore ? "加载中…" : "加载更旧记录")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppColors.sendButton)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMore)
                        .padding(.vertical, 4)
                    }
                    ForEach(renderItems) { item in
                        switch item.kind {
                        case .entry(let e): entryRow(e)
                        case .toolGroup(let group): toolGroup(group)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder private func entryRow(_ e: ImTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel(e))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.secondaryText)
                if e.hasBlob {
                    Text("大内容已截断")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.tertiaryText)
                }
            }
            if !e.summary.isEmpty {
                Text(e.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.primaryText)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppColors.sidebar, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func toolGroup(_ group: [ImTranscriptEntry]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group) { entryRow($0) }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                Text("执行了 \(group.count) 个操作")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.horizontal, 4)
    }

    private func roleLabel(_ e: ImTranscriptEntry) -> String {
        switch e.role {
        case "user": return "我"
        case "assistant": return "Claude"
        default: return e.type
        }
    }

    // MARK: - Folding

    private enum RenderKind {
        case entry(ImTranscriptEntry)
        case toolGroup([ImTranscriptEntry])
    }
    private struct RenderItem: Identifiable {
        let id: String
        let kind: RenderKind
    }

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

    // MARK: - Loading

    private func loadInitial() async {
        isLoading = true
        let page = await vm.fetchTranscript(conversationId: sessionId)
        entries = page.entries
        hasMoreBefore = page.hasMoreBefore
        isLoading = false
    }

    private func loadOlder() async {
        guard let firstId = entries.first?.id, !isLoadingMore else { return }
        isLoadingMore = true
        let page = await vm.fetchTranscript(conversationId: sessionId, anchor: firstId)
        entries = page.entries + entries
        hasMoreBefore = page.hasMoreBefore
        isLoadingMore = false
    }
}
