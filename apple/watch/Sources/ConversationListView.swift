import SwiftUI
import ChatKit

struct ConversationListView: View {
    @Environment(WatchAppModel.self) private var model

    /// Visible (synced deletes/folds/blacklist hidden), most-recent first, capped
    /// — a tiny screen doesn't need 157 rows. Pinned always stay.
    private var rows: [ImConversationDTO] {
        Array(model.visible.prefix(50))
    }

    var body: some View {
        List {
            if let status = connectionStatus {
                Text(status.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(status.color, in: Capsule())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .onTapGesture {
                        // After it gives up (.failed), the status line IS the manual
                        // reconnect button.
                        if case .failed = model.connectionState {
                            Task { await model.reconnect() }
                        }
                    }
            }
            ForEach(rows) { conv in
                NavigationLink(value: conv) {
                    row(conv)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        model.setDeleted(conv.id, true)
                    } label: { Label("删除", systemImage: "trash") }
                    Button {
                        model.setMuted(conv.id, !conv.isMuted)
                    } label: {
                        Label(conv.isMuted ? "取消静音" : "静音",
                              systemImage: conv.isMuted ? "bell" : "bell.slash")
                    }.tint(.indigo)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        model.setFolded(conv.id, true)
                    } label: { Label("折叠", systemImage: "rectangle.stack") }.tint(.gray)
                }
            }
            if rows.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
        .refreshable { await model.pullToRefresh() }
        .navigationTitle("ClaudeChat")
        .navigationDestination(for: ImConversationDTO.self) { conv in
            WatchChatView(conversation: conv)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ServerSetupView() } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    /// Top status line — shown ONLY when not online (this inline line IS the
    /// banner on the tiny watch screen).
    private var connectionStatus: (text: String, color: Color)? {
        switch model.connectionState {
        case .online:
            return nil
        case .reconnecting:
            return ("重连中…", .orange)
        case .offline:
            return ("网络不可用", .gray)
        case .failed:
            return ("连接失败 · 点击重连", .red)
        }
    }

    private func row(_ conv: ImConversationDTO) -> some View {
        let n = model.unread[conv.id] ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.displayName(for: conv))
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if n > 0 {
                    Text(n > 99 ? "99+" : "\(n)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
            }
            if model.thinkingIds.contains(conv.id) {
                Text("正在输入…")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else if let p = conv.lastMessagePreview, !p.isEmpty {
                Text(p)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if model.isSyncing {
                ProgressView()
                Text("正在同步…").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if let err = model.lastError {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(err).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("暂无会话").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
