import SwiftUI
import ChatKit

struct RootTabView: View {
    @Environment(IOSAppModel.self) private var model

    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label("AI", systemImage: "message.fill") }
                .badge(model.totalUnread)
            ContactsView()
                .tabItem { Label("通讯录", systemImage: "person.2.fill") }
            DiscoverTab()
                .tabItem { Label("发现", systemImage: "safari.fill") }
            MeTab()
                .tabItem { Label("我", systemImage: "person.crop.circle.fill") }
        }
        // Tool-approval prompt (only when the user enabled "工具执行前确认").
        // Dismissing without choosing leaves the server to auto-execute after
        // its 10-minute timeout, so a missed prompt never stalls the run.
        .sheet(item: Binding(
            get: { model.pendingApproval },
            set: { if $0 == nil { model.pendingApproval = nil } })
        ) { req in
            ToolApprovalSheet(request: req)
                .environment(model)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastBanner(text: toast.text)
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_800_000_000)
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .overlay(alignment: .top) {
            // PERSISTENT connection indicator — stays visible the whole time you're
            // not online (the old banner was transient, so a drop showed nothing
            // after 3s). Tappable to reconnect once it has given up (.failed).
            if let s = connectionStatusBar {
                Text(s.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(s.color.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .padding(.top, 6)
                    .onTapGesture {
                        if case .failed = model.connectionState { Task { await model.reconnect() } }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .animation(.default, value: model.connectionState)
    }

    /// Persistent top status while not connected (nil when online → bar hidden).
    private var connectionStatusBar: (text: String, color: Color)? {
        switch model.connectionState {
        case .online:        return nil
        case .reconnecting:  return ("连接断开，正在重连…", .orange)
        case .offline:       return ("已离线 · 网络不可用", .gray)
        case .failed:        return ("连接失败 · 点击重连", .red)
        }
    }
}

/// Transient failure banner (toast) shown at the top of the tab view.
private struct ToastBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.black.opacity(0.82), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(.horizontal, 24)
    }
}

/// Compact approval card: which tool wants to run, its input, and allow/deny.
struct ToolApprovalSheet: View {
    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: IOSAppModel.ToolApprovalRequest

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(WC.accent)
                Text("允许执行工具?")
                    .font(.system(size: 18, weight: .semibold))
                Text(request.toolName)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(WC.accent)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            ScrollView {
                Text(prettyInput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 220)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            Text("10 分钟未选择将自动执行。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

            HStack(spacing: 12) {
                Button {
                    Task { await model.respondToApproval(request.id, allow: false) }
                    dismiss()
                } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    Task { await model.respondToApproval(request.id, allow: true) }
                    dismiss()
                } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WC.accent)
            }
            .padding(16)
        }
        .presentationDetents([.medium])
    }

    /// Pretty-print the tool input JSON; fall back to the raw string.
    private var prettyInput: String {
        guard let data = request.input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8)
        else { return request.input }
        return s
    }
}
