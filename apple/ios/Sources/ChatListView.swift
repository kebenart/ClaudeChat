import SwiftUI
import ChatKit

struct ChatListView: View {
    @Environment(IOSAppModel.self) private var model
    @State private var search = ""
    @State private var renameTarget: ImConversationDTO?
    @State private var renameText = ""
    @State private var path = NavigationPath()
    @State private var showNew = false
    @State private var foldedExpanded = false

    /// 3-day retention (mirrors web WeChatSidebar / macOS SessionListViewModel):
    /// hide stale chats but always keep pinned / live / typing / unread ones.
    private var retained: [ImConversationDTO] {
        let cutoff = Date().timeIntervalSince1970 * 1000 - 3 * 24 * 60 * 60 * 1000
        return model.conversations.filter { c in
            // server-synced soft delete + optimistic local guard (hidden until
            // the server confirms, so a racing /sync can't resurrect it early).
            if c.isDeleted || model.locallyDeletedIds.contains(c.id) { return false }
            if model.isBlacklisted(c) { return false }
            let ms = Double(c.lastActivityAt > 1_000_000_000_000 ? c.lastActivityAt : c.lastActivityAt * 1000)
            return c.isPinned
                || model.liveSessionIds.contains(c.id)
                || model.thinkingConversationIds.contains(c.id)
                || (model.unread[c.id] ?? 0) > 0
                || ms >= cutoff
        }
    }

    private var visible: [ImConversationDTO] {
        let base = retained.filter { !model.isFolded($0.id) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            ($0.title ?? "").lowercased().contains(q) ||
            ($0.lastMessagePreview ?? "").lowercased().contains(q)
        }
    }

    /// Folded chats (WeChat "折叠的聊天"): kept out of the main list, shown under
    /// a single collapsible row.
    private var foldedConvs: [ImConversationDTO] {
        retained.filter { model.isFolded($0.id) }
    }

    private func isLive(_ conv: ImConversationDTO) -> Bool {
        model.liveSessionIds.contains(conv.id) || model.thinkingConversationIds.contains(conv.id)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !foldedConvs.isEmpty {
                    Button {
                        withAnimation { foldedExpanded.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text("折叠的聊天").font(.system(size: 15))
                            Text("\(foldedConvs.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    if foldedExpanded {
                        ForEach(foldedConvs) { conv in rowLink(conv, folded: true) }
                    }
                }
                ForEach(visible) { conv in rowLink(conv, folded: false) }
            }
            .listStyle(.plain)
            .refreshable { await model.pullRefresh() }
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ImConversationDTO.self) { conv in
                ChatDetailView(conversation: conv)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Small top "加载中" spinner while a sync runs (pull-to-refresh
                    // style) — shown on cold start too, so there's NO full-screen
                    // blocker; the cached list (if any) stays visible underneath.
                    if model.isSyncing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("加载中").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewSessionSheet { newConvId in
                    if let conv = model.conversations.first(where: { $0.id == newConvId }) {
                        path.append(conv)
                    }
                }
                .environment(model)
            }
            .searchable(text: $search, prompt: "搜索")
            .overlay {
                // No full-screen "正在同步" blocker — cold-start sync shows only the
                // small top spinner (pull-to-refresh style) and the cached list stays
                // visible. Empty / error states appear only once the sync settles.
                if model.conversations.isEmpty && !model.isSyncing {
                    if let err = model.lastSyncError {
                        ContentUnavailableView {
                            Label("无法加载会话", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("\(err)\n服务器: \(model.serverURLString)\n请检查「我」→ 服务器地址是否正确,以及网络。")
                        }
                    } else {
                        ContentUnavailableView("暂无会话", systemImage: "message")
                    }
                }
            }
            .alert("设置备注名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("备注名（最多10字）", text: $renameText)
                Button("保存") {
                    if let t = renameTarget { model.setNote(t.id, renameText) }
                    renameTarget = nil
                }
                Button("清除", role: .destructive) {
                    if let t = renameTarget { model.setNote(t.id, nil) }
                    renameTarget = nil
                }
                Button("取消", role: .cancel) { renameTarget = nil }
            }
        }
    }

    @ViewBuilder private func rowLink(_ conv: ImConversationDTO, folded: Bool) -> some View {
        // The navigation link lives in the row's background (invisible but still
        // tappable) so the List doesn't draw its `>` disclosure chevron.
        row(conv)
            .contentShape(Rectangle())
            .background(NavigationLink(value: conv) { EmptyView() }.opacity(0))
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    model.setDeleted(conv.id, true)
                } label: { Label("删除", systemImage: "trash") }
                Button {
                    Task { await model.setPinned(conv.id, !conv.isPinned) }
                } label: {
                    Label(conv.isPinned ? "取消置顶" : "置顶", systemImage: conv.isPinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
                Button {
                    renameText = conv.note ?? conv.title ?? ""
                    renameTarget = conv
                } label: { Label("备注", systemImage: "pencil") }
                .tint(.gray)
                Button {
                    Task { await model.setMuted(conv.id, !conv.isMuted) }
                } label: {
                    Label(conv.isMuted ? "取消静音" : "静音", systemImage: conv.isMuted ? "bell" : "bell.slash")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    withAnimation { model.setFolded(conv.id, !folded) }
                } label: {
                    Label(folded ? "恢复" : "折叠", systemImage: folded ? "tray.and.arrow.up" : "rectangle.stack")
                }
                .tint(folded ? .green : .gray)
                if !folded, (model.unread[conv.id] ?? 0) > 0 {
                    Button {
                        Task { await model.markRead(conv.id) }
                    } label: { Label("已读", systemImage: "envelope.open") }
                    .tint(.blue)
                }
            }
    }

    @ViewBuilder private func row(_ conv: ImConversationDTO) -> some View {
        HStack(spacing: 12) {
            IOSAvatar(seed: conv.id, title: conv.title ?? "C", size: 48)
                .overlay(alignment: .topTrailing) {
                    if let n = model.unread[conv.id], n > 0 {
                        Text(n > 99 ? "99+" : "\(n)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .offset(x: 6, y: -4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isLive(conv) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 1, y: 1)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if conv.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(model.displayName(for: conv).clampedNickname)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.relativeTime(conv.lastActivityAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if model.thinkingConversationIds.contains(conv.id) {
                        Text("正在输入中…")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    } else {
                        Text(conv.lastMessagePreview ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if conv.isMuted {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(conv.isPinned ? Color(.secondarySystemBackground) : Color(.systemBackground))
    }

    /// WeChat-style relative timestamp. `lastActivityAt` may be epoch seconds or
    /// milliseconds depending on the source; normalize defensively.
    static func relativeTime(_ raw: Int) -> String {
        guard raw > 0 else { return "" }
        let seconds: TimeInterval = raw > 1_000_000_000_000 ? TimeInterval(raw) / 1000 : TimeInterval(raw)
        let date = Date(timeIntervalSince1970: seconds)
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天"
        }
        if let d = cal.dateComponents([.day], from: date, to: Date()).day, d < 7 {
            let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
            return "周" + weekdays[cal.component(.weekday, from: date) - 1]
        }
        f.dateFormat = "MM/dd"
        return f.string(from: date)
    }
}
