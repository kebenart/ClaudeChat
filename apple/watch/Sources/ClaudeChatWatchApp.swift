import SwiftUI

@main
struct ClaudeChatWatchApp: App {
    @State private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Auth gate → conversation list. Bootstraps once on first appearance:
/// restores a stored token / dev-bypass, else shows the login screen.
struct RootView: View {
    @Environment(WatchAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var didBootstrap = false

    var body: some View {
        NavigationStack {
            if model.isAuthenticated {
                ConversationListView()
            } else {
                WatchLoginView()
            }
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await model.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // REST refresh + resume polling. Don't auto-retry once we've given
                // up (.failed) — wait for a manual tap on the status line.
                if model.isAuthenticated && model.connectionState != .failed {
                    Task { await model.reconnect() }
                }
            case .background, .inactive:
                // Stop the poll loop to save battery while off-wrist.
                model.stopPolling()
            @unknown default:
                break
            }
        }
    }
}
