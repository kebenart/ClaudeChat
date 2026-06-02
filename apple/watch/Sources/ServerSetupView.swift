import SwiftUI
import ChatKit

/// Minimal server config: shows the current URL and lets the user re-point the
/// watch (via dictation/scribble) if needed. Defaults to the domain so it works
/// out of the box.
struct ServerSetupView: View {
    @Environment(WatchAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var usage: ClaudeUsageLimits?

    var body: some View {
        Form {
            Section("服务器地址") {
                TextField("https://…", text: $url)
                    .font(.system(size: 13))
            }
            if let usage {
                Section("用量") {
                    usageRow("5 小时", usage.fiveHour)
                    usageRow("7 天", usage.sevenDay)
                }
            }
            Section {
                Button("连接") {
                    model.serverURLString = url
                    Task { await model.connect() }
                    dismiss()
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(model.isConnected ? "已连接" : "未连接")
                        .foregroundStyle(model.isConnected ? .green : .secondary)
                }
                .font(.system(size: 13))
            }
            if model.isAuthenticated {
                Section {
                    Button("退出登录", role: .destructive) {
                        Task { await model.logout() }
                        dismiss()
                    }
                    .font(.system(size: 13))
                }
            }
        }
        .navigationTitle("设置")
        .onAppear { url = model.serverURLString }
        .task { usage = await model.loadUsageLimits() }
    }

    /// One compact "5 小时 42%" row, percentage colored by load.
    @ViewBuilder
    private func usageRow(_ title: String, _ window: UsageWindow?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let window {
                Text("\(Int(window.utilizationPct.rounded()))%")
                    .foregroundStyle(usageColor(window.utilizationPct))
            } else {
                Text("暂无").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
    }

    private func usageColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}
