import AppKit
import SwiftUI
import SwiftData
import ChatKit
import ChatKitUI

// MARK: - AppKit bootstrap
//
// SwiftUI's App protocol / WindowGroup didn't reliably materialize a window
// when run from an SPM-built executable inside a hand-rolled .app bundle, so
// we drive AppKit ourselves and hand SwiftUI the contents via NSHostingController.

// macOS Mojave+ disables sub-pixel font smoothing by default, which makes
// SwiftUI text — and Chinese characters especially — look soft on Retina
// displays. Force-enable it for this app before any drawing happens. Apps
// like VSCode / Slack do the same. The value `2` = medium strength, which
// matches what subpixel rendering used to default to.
UserDefaults.standard.set(2, forKey: "AppleFontSmoothing")
CFPreferencesSetAppValue("AppleFontSmoothing" as CFString,
                         2 as CFPropertyList,
                         kCFPreferencesCurrentApplication)

let app = NSApplication.shared

// MARK: - Real dependency graph

let keychain = KeychainStore()
let profileStore = ServerProfileStore()

// Dev override: CLAUDECHAT_SERVER_URL forces the backend (e.g. point at the dev
// server on :3011 that has the IM API + DEV_AUTH_BYPASS). It's upserted as the
// most-recent profile so the whole boot path picks it up.
let envServerURL = ProcessInfo.processInfo.environment["CLAUDECHAT_SERVER_URL"]
    .flatMap { URL(string: $0) }
if let envServerURL {
    profileStore.upsert(
        ServerProfile(url: envServerURL, displayName: "ENV (\(envServerURL.absoluteString))", username: "")
    )
}

// Seed a default profile on first launch so the user sees something in the picker.
if profileStore.list().isEmpty {
    profileStore.upsert(
        ServerProfile(
            url: URL(string: "http://127.0.0.1:3001")!,
            displayName: "本地 (127.0.0.1:3001)",
            username: ""
        )
    )
}

// Pick a profile id for the on-disk SwiftData store. Each ServerProfile gets
// its own database; before login we use the most-recent (or first) profile.
let bootProfileId: UUID = profileStore.mostRecent()?.id
    ?? profileStore.list().first?.id
    ?? UUID()

let modelContainer: ModelContainer
do {
    modelContainer = try StorageContainer.makeOnDisk(profileId: bootProfileId)
} catch {
    NSLog("[ClaudeChat] makeOnDisk failed (\(error)); falling back to in-memory store")
    modelContainer = try! StorageContainer.makeInMemory()
}

let storage = Storage(container: modelContainer)

// Default base URL = the most recent profile's URL; APIClient.setBaseURL() will
// also be called after login if the user picks a different profile.
let bootBaseURL = envServerURL
    ?? profileStore.mostRecent()?.url
    ?? URL(string: "http://127.0.0.1:3001")!

let apiClient = APIClient(baseURL: bootBaseURL)
let socket = ChatSocket()

let appVM = AppViewModel(
    apiClient: apiClient,
    socket: socket,
    storage: storage,
    keychain: keychain,
    serverProfileStore: profileStore
)
// Wire the IM controller using the concrete Storage type (IMController requires
// Storage, not the StorageProtocol existential, so it must be done here where
// the concrete type is known).
let imController = IMController(storage: storage)
appVM.imController = imController

let appSettings = AppSettings()
// Apply the persisted light/dark/system appearance to NSApp at launch (before
// the window appears) so the saved preference takes effect without a re-toggle.
appSettings.applyAppearance()

// DEV — synchronous bypass probe.
//
// The async `bootstrapAuth()` in RootView.task races against the SwiftUI tree
// mounting. On a slow first network round-trip the user briefly sees LoginView
// before we flip to .loggedIn. To eliminate the flash completely we do a
// blocking 1s probe HERE — before the View tree exists — so authState is
// already correct on the very first body computation.
//
// If the server is unreachable or doesn't advertise bypass, we leave the
// default .bootstrapping state and the async bootstrap takes over.
func probeDevBypassSync(baseURL: URL, timeout: TimeInterval) -> Bool {
    let url = baseURL.appendingPathComponent("/api/auth/status")
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "GET"
    let sem = DispatchSemaphore(value: 0)
    var bypass = false
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        bypass = (json["devBypass"] as? Bool) ?? false
    }.resume()
    _ = sem.wait(timeout: .now() + timeout)
    return bypass
}

if probeDevBypassSync(baseURL: bootBaseURL, timeout: 1.0) {
    NSLog("[ClaudeChat] DEV_AUTH_BYPASS detected — entering main UI without login")
    appVM.currentServerProfile = profileStore.mostRecent() ?? profileStore.list().first
    // Placeholder user; bootstrapAuth() refreshes with the real one async.
    appVM.authState = .loggedIn(user: User(id: 1, username: "admin"))
}

// Install the AppDelegate before app.run() so it can build the menu bar and
// receive applicationDidFinishLaunching.
let delegate = AppDelegate(appVM: appVM, appSettings: appSettings)
app.delegate = delegate

// Start the WebSocket event loop. It consumes socket.events for as long as
// the app runs and dispatches to storage / unread counts via AppViewModel.
appVM.startEventLoop()

// MARK: - Root SwiftUI tree

let rootView = RootView(storage: storage)
    .environment(appVM)
    .environment(appSettings)
    .environment(\.chatFontSize, appSettings.chatFontSize)

let hosting = NSHostingController(rootView: rootView)

let window = NSWindow(contentViewController: hosting)
window.setContentSize(NSSize(width: 1100, height: 720))
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
window.title = "Claude Chat"
window.minSize = NSSize(width: 900, height: 600)
window.center()

// NOTE: do NOT manually set `wantsLayer = true` on the hosting view here.
// SwiftUI/NSHostingController manage their own layer hierarchy with the
// correct contentsScale for the screen. Wrapping the whole view in a
// hand-rolled CALayer rasterizes the text into a bitmap that then scales
// wrong on Retina — exactly the blur we were trying to fix.

// Let the AppDelegate act as the window delegate so the red close button hides
// the window (WeChat-style) instead of quitting the app.
delegate.registerMainWindow(window)

window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()

app.run()

// MARK: - RootView

/// Switches on auth state to show Login / TOTP / Main window.
struct RootView: View {
    let storage: Storage
    @Environment(AppViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    @State private var didBootstrap = false

    var body: some View {
        Group {
            switch vm.authState {
            case .bootstrapping:
                BootstrapSplash()
            case .loggedOut:
                LoginView()
            case .totpRequired(let totpToken):
                TOTPView(totpToken: totpToken)
            case .totpSetupRequired:
                TOTPSetupView()
            case .loggedIn:
                MainWindowView(storage: storage, apiClient: vm.apiClient)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authStateKey)
        .task {
            // Run once: detect DEV_AUTH_BYPASS or restore a cached token before
            // the user sees LoginView. Re-running on subsequent body builds
            // would clobber state from a real login.
            guard !didBootstrap else { return }
            didBootstrap = true
            await vm.bootstrapAuth()
        }
    }

    private var authStateKey: String {
        switch vm.authState {
        case .bootstrapping:      return "boot"
        case .loggedOut:          return "out"
        case .totpRequired:       return "totp"
        case .totpSetupRequired:  return "totp-setup"
        case .loggedIn:           return "in"
        }
    }
}

/// Splash shown while `bootstrapAuth()` probes /api/auth/status and restores
/// the cached token. Without it the user would see LoginView flash for one
/// run-loop tick before authState flipped to .loggedIn.
private struct BootstrapSplash: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 7/255, green: 193/255, blue: 96/255))
            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
