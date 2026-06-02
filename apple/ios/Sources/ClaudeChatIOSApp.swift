import SwiftUI
import ChatKit

@main
struct ClaudeChatIOSApp: App {
    @State private var model = IOSAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentRootView()
                .environment(model)
                .task {
                    IOSNotifications.requestAuthorization()
                    // Restore a stored token, else auto-skip only if the server
                    // runs in DEV_AUTH_BYPASS, else show the login screen.
                    await model.bootstrap()
                }
                .onChange(of: scenePhase) { old, new in
                    // iOS suspends the WebSocket in the background; rebuild it on
                    // return so sends/receives aren't lost to a half-open socket.
                    // NOTE: returning to the foreground always goes
                    // background → inactive → active, so by the time we reach
                    // .active the previous phase is .inactive, never .background.
                    // Guarding on `old == .background` therefore essentially never
                    // fired — the app never re-synced on foreground and a reply
                    // that landed while away was only pulled by a manual refresh.
                    // Reconnect on ANY transition into .active.
                    // Don't auto-retry once we've given up (.failed) — the user
                    // must tap 重连 in the 我 tab to restart the attempts.
                    if new == .active && old != .active && model.connectionState != .failed {
                        Task { await model.reconnect() }
                    }
                }
        }
    }
}

/// Root switcher: login screen until `model.isAuthenticated`, then the main tab UI.
private struct ContentRootView: View {
    @Environment(IOSAppModel.self) private var model

    var body: some View {
        if model.isAuthenticated {
            RootTabView()
        } else {
            LoginView()
        }
    }
}
