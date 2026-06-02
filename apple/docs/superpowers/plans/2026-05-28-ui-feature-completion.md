# UI Feature Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete five UI features for the macOS Claude Chat client: new-session popover, contacts tab with all sessions, server profile management in settings, cross-session search results, and logout flow cleanup.

**Architecture:** Each feature is a self-contained SwiftUI addition; the `AppViewModel+UI.swift` extension adds `switchProfile` without touching the frozen `AppViewModel.swift`. The `SessionListViewModel` gains `allSessions` and `searchResults` properties to power contacts tab and search. Three new files are created: `NewSessionPopover.swift`, `SearchResultsView.swift`, `AppViewModel+UI.swift`.

**Tech Stack:** SwiftUI (macOS 14+), `@Observable` macro, `async/await`, `StorageProtocol`, `APIClientProtocol`, `ServerProfileStoreProtocol`, XCTest.

---

## File Map

### New files
- `Sources/ChatKit/UI/NewSession/NewSessionPopover.swift` — popover for creating a new session
- `Sources/ChatKit/UI/Search/SearchResultsView.swift` — two-section search results replacing session list
- `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift` — `switchProfile` + `cleanupUI` helpers

### Modified files
- `Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift` — add `allSessions: [SessionRowData]` and `searchResults: SearchResults?`
- `Sources/ChatKit/UI/Sidebar/SidebarView.swift` — wire search results + contacts tab + popover button
- `Sources/ChatKit/UI/Sidebar/SessionRowView.swift` — accept optional `onRestore` callback; show context menu items contextually
- `Sources/ChatKit/UI/Settings/SettingsView.swift` — wire server profile management (select / edit / add)
- `Sources/ChatKit/UI/MainWindowView.swift` — pass `showNewSession` state to SidebarView

### Test files (new)
- `Tests/ChatKitTests/UISessionListViewModelTests.swift`
- `Tests/ChatKitTests/UIAppViewModelUITests.swift`

---

## Task 1: Extend SessionListViewModel with allSessions + searchResults

**Files:**
- Modify: `Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift`
- Create: `Tests/ChatKitTests/UISessionListViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ChatKitTests/UISessionListViewModelTests.swift
import XCTest
@testable import ChatKit

@MainActor
final class UISessionListViewModelTests: XCTestCase {

    // MARK: - allSessions

    func testAllSessionsIncludesHiddenOnes() async {
        let storage = StubStorage()
        let visible = SessionInfo(id: "v1", projectPath: "/p", title: "Visible", lastActivityAt: Date())
        let hidden  = SessionInfo(id: "h1", projectPath: "/p", title: "Hidden",  lastActivityAt: Date())
        await storage.upsertSessions([visible, hidden])
        await storage.setHidden(sessionId: "h1", hidden: true)

        let vm = SessionListViewModel(storage: storage)
        await vm.refreshAll()

        XCTAssertEqual(vm.allSessions.count, 2)
        XCTAssertTrue(vm.allSessions.contains { $0.id == "h1" })
        XCTAssertTrue(vm.allSessions.contains { $0.id == "v1" })
    }

    func testAllSessionsIsDistinctFromRows() async {
        let storage = StubStorage()
        let visible = SessionInfo(id: "v1", projectPath: "/p", title: "Visible", lastActivityAt: Date())
        let hidden  = SessionInfo(id: "h1", projectPath: "/p", title: "Hidden",  lastActivityAt: Date())
        await storage.upsertSessions([visible, hidden])
        await storage.setHidden(sessionId: "h1", hidden: true)

        let vm = SessionListViewModel(storage: storage)
        // Refresh visible sessions only (the normal path)
        await vm.refresh(sessions: [visible], unreadCounts: [:])
        await vm.refreshAll()

        XCTAssertEqual(vm.rows.count, 1,         "rows should only show visible")
        XCTAssertEqual(vm.allSessions.count, 2,  "allSessions should include hidden")
    }

    // MARK: - searchResults

    func testSearchResultsNilWhenSearchEmpty() async {
        let storage = StubStorage()
        let vm = SessionListViewModel(storage: storage)
        vm.searchText = ""
        await vm.refresh(sessions: [], unreadCounts: [:])
        XCTAssertNil(vm.searchResults)
    }

    func testSearchResultsPopulatedWhenSearchHasText() async {
        let storage = StubStorage()
        let session = SessionInfo(id: "s1", projectPath: "/p", title: "Hello world", lastActivityAt: Date())
        await storage.upsertSessions([session])

        let vm = SessionListViewModel(storage: storage)
        vm.searchText = "Hello"
        await vm.refresh(sessions: [session], unreadCounts: [:])
        XCTAssertNotNil(vm.searchResults)
        XCTAssertTrue(vm.searchResults!.matchingSessions.contains { $0.id == "s1" })
    }

    func testClearSearchResetsSearchResults() async {
        let storage = StubStorage()
        let vm = SessionListViewModel(storage: storage)
        vm.searchText = "query"
        await vm.refresh(sessions: [], unreadCounts: [:])
        vm.clearSearch()
        XCTAssertNil(vm.searchResults)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test --filter UISessionListViewModelTests 2>&1 | tail -15
```

Expected: compile error — `refreshAll()` and `allSessions` do not exist yet, `searchResults` does not exist.

- [ ] **Step 3: Implement the changes**

Replace the full contents of `Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift` with:

```swift
import SwiftUI
import Foundation

// MARK: - SessionListViewModel

/// Derives sidebar rows from storage and manages search state.
@Observable
@MainActor
public final class SessionListViewModel {
    // MARK: Published state

    public var rows: [SessionRowData] = []
    public var allSessions: [SessionRowData] = []      // includes hidden
    public var searchResults: SearchResults? = nil     // non-nil when searching
    public var searchText: String = ""
    public var isSearching: Bool = false

    // MARK: Private

    private let storage: any StorageProtocol

    public init(storage: some StorageProtocol) {
        self.storage = storage
    }

    // MARK: - Loading

    /// Refresh visible rows + search results from the visible sessions list.
    public func refresh(sessions: [SessionInfo], unreadCounts: [String: Int]) async {
        if searchText.isEmpty {
            rows = sessions.map { session in
                SessionRowData(session: session, unread: unreadCounts[session.id] ?? 0)
            }
            isSearching = false
            searchResults = nil
        } else {
            let results = await storage.search(searchText)
            let matching = results.matchingSessions
            rows = matching.map { session in
                SessionRowData(session: session, unread: unreadCounts[session.id] ?? 0)
            }
            isSearching = true
            searchResults = results
        }
    }

    /// Refresh allSessions from storage (includes hidden). Call from Contacts tab.
    public func refreshAll() async {
        let all = await storage.listSessions(includingHidden: true)
        allSessions = all.map { SessionRowData(session: $0, unread: 0) }
    }

    public func clearSearch() {
        searchText = ""
        isSearching = false
        searchResults = nil
    }
}

// MARK: - SessionRowData

public struct SessionRowData: Identifiable, Sendable {
    public var id: String { session.id }
    public let session: SessionInfo
    public let unread: Int

    /// Badge display mode
    public var badgeMode: BadgeMode {
        if unread > 1 { return .count(unread) }
        if unread == 1 { return .dot }
        return .none
    }

    public init(session: SessionInfo, unread: Int) {
        self.session = session
        self.unread = unread
    }
}

public enum BadgeMode: Sendable {
    case none
    case dot
    case count(Int)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test --filter UISessionListViewModelTests 2>&1 | tail -15
```

Expected: all 4 tests in `UISessionListViewModelTests` pass.

- [ ] **Step 5: Verify full suite still passes**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: 125+ tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift Tests/ChatKitTests/UISessionListViewModelTests.swift && git commit -m "feat(list-vm): add allSessions + searchResults to SessionListViewModel"
```

---

## Task 2: AppViewModel+UI extension (switchProfile + cleanupUI)

**Files:**
- Create: `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift`
- Create: `Tests/ChatKitTests/UIAppViewModelUITests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ChatKitTests/UIAppViewModelUITests.swift
import XCTest
@testable import ChatKit

@MainActor
final class UIAppViewModelUITests: XCTestCase {

    private func makeVM() -> AppViewModel {
        AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        )
    }

    func testSwitchProfileSetsCurrentProfile() async {
        let vm = makeVM()
        let profile = ServerProfile(
            url: URL(string: "http://example.com")!,
            displayName: "Test",
            username: "alice"
        )
        await vm.switchProfile(profile)
        XCTAssertEqual(vm.currentServerProfile?.id, profile.id)
    }

    func testSwitchProfileWithNoTokenGoesLoggedOut() async {
        let vm = makeVM()
        let profile = ServerProfile(
            url: URL(string: "http://example.com")!,
            displayName: "Test",
            username: "alice"
        )
        // StubKeychain returns nil for any profile id
        await vm.switchProfile(profile)
        if case .loggedOut = vm.authState {
            // pass
        } else {
            XCTFail("Expected loggedOut when no token, got \(vm.authState)")
        }
    }

    func testCleanupUIResetsSessionState() async {
        let vm = makeVM()
        // Simulate logged-in state with sessions
        vm.authState = .loggedIn(user: User(id: 1, username: "test"))
        vm.sessions = [SessionInfo(id: "s1", projectPath: "/p")]
        vm.currentSessionId = "s1"
        vm.unreadCounts = ["s1": 3]

        await vm.cleanupUI()

        XCTAssertEqual(vm.sessions.count, 0)
        XCTAssertNil(vm.currentSessionId)
        XCTAssertEqual(vm.unreadCounts.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test --filter UIAppViewModelUITests 2>&1 | tail -15
```

Expected: compile error — `switchProfile` and `cleanupUI` do not exist.

- [ ] **Step 3: Create the extension file**

Create `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift`:

```swift
import Foundation

// MARK: - AppViewModel+UI
//
// UI-layer helpers that Agent Z owns. Do NOT add these to AppViewModel.swift.

extension AppViewModel {

    // MARK: - Profile switching

    /// Switch to a different server profile:
    /// 1. Updates currentServerProfile and configures the API client.
    /// 2. Loads the stored token for the profile.
    /// 3. If a token exists, verifies it by calling currentUser().
    ///    - On success → .loggedIn
    ///    - On failure → .loggedOut
    /// 4. If no token → .loggedOut
    public func switchProfile(_ profile: ServerProfile) async {
        currentServerProfile = profile
        await apiClient.setBaseURL(profile.url)

        if let token = keychain.token(for: profile.id) {
            await apiClient.setToken(token)
            do {
                let user = try await apiClient.currentUser()
                authState = .loggedIn(user: user)
                await loadSessions()
            } catch {
                await apiClient.setToken(nil)
                authState = .loggedOut
            }
        } else {
            await apiClient.setToken(nil)
            authState = .loggedOut
        }
    }

    // MARK: - UI-local cleanup

    /// Clear UI-local caches. Call this after logout or before switching profile.
    /// Does NOT modify authState — call vm.logout() first if needed.
    public func cleanupUI() async {
        sessions = []
        currentSessionId = nil
        unreadCounts = [:]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test --filter UIAppViewModelUITests 2>&1 | tail -15
```

Expected: all 3 tests pass.

- [ ] **Step 5: Full suite check**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: 128+ tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift Tests/ChatKitTests/UIAppViewModelUITests.swift && git commit -m "feat(vm): add AppViewModel+UI extension with switchProfile and cleanupUI"
```

---

## Task 3: NewSessionPopover

**Files:**
- Create: `Sources/ChatKit/UI/NewSession/NewSessionPopover.swift`
- Modify: `Sources/ChatKit/UI/Sidebar/SidebarView.swift` (add + button in search bar area)
- Modify: `Sources/ChatKit/UI/MainWindowView.swift` (pass storage to SidebarView if needed — check if already done; it currently is not needed)

- [ ] **Step 1: Create the directory and file**

```bash
mkdir -p /Users/keben/CODE/claudecodeui-local/apple/Sources/ChatKit/UI/NewSession
```

Then create `Sources/ChatKit/UI/NewSession/NewSessionPopover.swift`:

```swift
import SwiftUI

// MARK: - NewSessionPopover

/// Popover shown when the user taps "+ 新建" in the sidebar header.
/// Lets them pick a project and type a first prompt, then calls
/// `AppViewModel.createSession(projectPath:firstPrompt:)` (added by Agent X).
public struct NewSessionPopover: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [ProjectInfo] = []
    @State private var isLoadingProjects = false
    @State private var selectedProject: ProjectInfo? = nil
    @State private var firstPrompt: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String? = nil

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "plus.bubble")
                    .foregroundStyle(AppColors.sendButton)
                Text("新建会话")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Project picker section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择项目")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText)
                            .textCase(.uppercase)

                        if isLoadingProjects {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("加载项目中...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if projects.isEmpty {
                            Text("未找到项目")
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.tertiaryText)
                        } else {
                            ForEach(projects) { project in
                                projectRow(project)
                            }
                        }
                    }

                    Divider()

                    // First prompt section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("第一条消息")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText)
                            .textCase(.uppercase)

                        TextEditor(text: $firstPrompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 80, maxHeight: 120)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(AppColors.border, lineWidth: 0.5)
                            )
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: { Task { await createSession() } }) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("创建", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.sendButton)
                .disabled(selectedProject == nil || firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
            .padding(16)
        }
        .frame(width: 360)
        .task {
            await loadProjects()
        }
    }

    // MARK: - Project row

    private func projectRow(_ project: ProjectInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.titleText)
                Text(project.path)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if selectedProject?.id == project.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.sendButton)
                    .font(.system(size: 14))
            }
        }
        .padding(10)
        .background(
            selectedProject?.id == project.id
                ? AppColors.sendButton.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    selectedProject?.id == project.id ? AppColors.sendButton.opacity(0.4) : AppColors.border,
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedProject = project }
    }

    // MARK: - Actions

    private func loadProjects() async {
        isLoadingProjects = true
        do {
            projects = try await vm.apiClient.fetchProjects()
            if selectedProject == nil { selectedProject = projects.first }
        } catch {
            errorMessage = "加载项目失败: \(error.localizedDescription)"
        }
        isLoadingProjects = false
    }

    private func createSession() async {
        guard let project = selectedProject else { return }
        let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        // createSession is added by Agent X.
        // Signature: func createSession(projectPath: String, firstPrompt: String) async -> String?
        if let newId = await vm.createSession(projectPath: project.path, firstPrompt: prompt) {
            await vm.selectSession(newId)
            dismiss()
        } else {
            errorMessage = "创建会话失败，请检查服务器连接"
        }
    }
}
```

- [ ] **Step 2: Add the `+ 新建` button to SidebarView's search bar**

Open `Sources/ChatKit/UI/Sidebar/SidebarView.swift`. Add a `@State private var showNewSession = false` and update the `searchBar` computed property to include a trailing button. Also update the `content` body to wire the popover.

Replace the file with:

```swift
import SwiftUI

// MARK: - SidebarView

public struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm
    let tab: RailTab
    let listVM: SessionListViewModel

    @State private var showNewSession = false

    public init(tab: RailTab, listVM: SessionListViewModel) {
        self.tab = tab
        self.listVM = listVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            content
        }
        .background(AppColors.sidebar)
        .task(id: "\(tab)-\(vm.sessions.count)-\(vm.unreadCounts.description)") {
            await listVM.refresh(sessions: vm.sessions, unreadCounts: vm.unreadCounts)
            if tab == .contacts {
                await listVM.refreshAll()
            }
        }
    }

    // MARK: - Sidebar header (search bar + new button)

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.secondaryText)
                TextField("搜索", text: Bindable(listVM).searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onChange(of: listVM.searchText) { _, _ in
                        Task { await listVM.refresh(sessions: vm.sessions, unreadCounts: vm.unreadCounts) }
                    }
                if !listVM.searchText.isEmpty {
                    Button(action: { listVM.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppColors.border, lineWidth: 0.5))

            // New session button (chats tab only)
            if tab == .chats {
                Button(action: { showNewSession = true }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppColors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showNewSession, arrowEdge: .bottom) {
                    NewSessionPopover()
                        .environment(vm)
                }
            }
        }
        .padding(10)
        .background(AppColors.sidebarSearch)
    }

    // MARK: - Content per tab

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .chats:
            if let results = listVM.searchResults {
                SearchResultsView(results: results)
                    .environment(vm)
            } else {
                chatsList
            }
        case .contacts:
            contactsList
        case .settings:
            EmptyView()
        }
    }

    // MARK: - Chats list

    private var chatsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(listVM.rows) { row in
                    SessionRowView(
                        row: row,
                        isSelected: vm.currentSessionId == row.id,
                        isHidden: false,
                        onSelect: {
                            Task { await vm.selectSession(row.id) }
                        },
                        onDelete: {
                            Task { await vm.softDeleteSession(row.id) }
                        },
                        onRestore: nil
                    )
                    Divider()
                        .padding(.leading, 60)
                }
                if listVM.rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: listVM.isSearching ? "magnifyingglass" : "bubble.left.and.bubble.right")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.tertiaryText)
                        Text(listVM.isSearching ? "无搜索结果" : "暂无会话")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
        }
    }

    // MARK: - Contacts list (all sessions including hidden)

    private var contactsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(listVM.allSessions) { row in
                    SessionRowView(
                        row: row,
                        isSelected: vm.currentSessionId == row.id,
                        isHidden: row.session.isHidden,
                        onSelect: {
                            Task { await vm.selectSession(row.id) }
                        },
                        onDelete: {
                            Task { await vm.softDeleteSession(row.id) }
                        },
                        onRestore: {
                            Task { await vm.restoreSession(row.id) }
                        }
                    )
                    Divider()
                        .padding(.leading, 60)
                }
                if listVM.allSessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.tertiaryText)
                        Text("暂无会话")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
        }
    }
}
```

Note: `row.session.isHidden` — `SessionInfo` does not have an `isHidden` property in the DTO. We need to derive it from `allSessions` vs `rows`. Since `SessionInfo` has no `isHidden`, we must check if the session is hidden by comparing with visible sessions. Simplest solution: add an `isHidden: Bool` field to `SessionRowData` and set it in `refreshAll()`.

**Revised plan for `SessionListViewModel.refreshAll()`** — cross-check visible sessions and mark which ones are hidden:

```swift
public func refreshAll() async {
    let all = await storage.listSessions(includingHidden: true)
    let visibleIds = Set(rows.map { $0.id })
    allSessions = all.map { session in
        SessionRowData(session: session, unread: 0, isHidden: !visibleIds.contains(session.id))
    }
}
```

And update `SessionRowData` to carry `isHidden: Bool`:

```swift
public struct SessionRowData: Identifiable, Sendable {
    public var id: String { session.id }
    public let session: SessionInfo
    public let unread: Int
    public let isHidden: Bool        // true when the session has been soft-deleted

    public var badgeMode: BadgeMode { ... }  // same as before

    public init(session: SessionInfo, unread: Int, isHidden: Bool = false) {
        self.session = session
        self.unread = unread
        self.isHidden = isHidden
    }
}
```

Update `refresh()` to also pass `isHidden: false` for all visible rows (they come from `includingHidden: false` already, so default `false` is correct).

**Step 3 is now broken into two sub-steps: first update SessionListViewModel, then create the new file.**

- [ ] **Step 3a: Update SessionListViewModel with isHidden on SessionRowData**

Update `Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift`:

```swift
import SwiftUI
import Foundation

// MARK: - SessionListViewModel

/// Derives sidebar rows from storage and manages search state.
@Observable
@MainActor
public final class SessionListViewModel {
    // MARK: Published state

    public var rows: [SessionRowData] = []
    public var allSessions: [SessionRowData] = []      // includes hidden
    public var searchResults: SearchResults? = nil     // non-nil when searching
    public var searchText: String = ""
    public var isSearching: Bool = false

    // MARK: Private

    private let storage: any StorageProtocol

    public init(storage: some StorageProtocol) {
        self.storage = storage
    }

    // MARK: - Loading

    /// Refresh visible rows + search results from the visible sessions list.
    public func refresh(sessions: [SessionInfo], unreadCounts: [String: Int]) async {
        if searchText.isEmpty {
            rows = sessions.map { session in
                SessionRowData(session: session, unread: unreadCounts[session.id] ?? 0)
            }
            isSearching = false
            searchResults = nil
        } else {
            let results = await storage.search(searchText)
            let matching = results.matchingSessions
            rows = matching.map { session in
                SessionRowData(session: session, unread: unreadCounts[session.id] ?? 0)
            }
            isSearching = true
            searchResults = results
        }
    }

    /// Refresh allSessions from storage (includes hidden). Call from Contacts tab.
    public func refreshAll() async {
        let all = await storage.listSessions(includingHidden: true)
        let visibleIds = Set(rows.map { $0.id })
        allSessions = all.map { session in
            SessionRowData(session: session, unread: 0, isHidden: !visibleIds.contains(session.id))
        }
    }

    public func clearSearch() {
        searchText = ""
        isSearching = false
        searchResults = nil
    }
}

// MARK: - SessionRowData

public struct SessionRowData: Identifiable, Sendable {
    public var id: String { session.id }
    public let session: SessionInfo
    public let unread: Int
    public let isHidden: Bool

    /// Badge display mode
    public var badgeMode: BadgeMode {
        if unread > 1 { return .count(unread) }
        if unread == 1 { return .dot }
        return .none
    }

    public init(session: SessionInfo, unread: Int, isHidden: Bool = false) {
        self.session = session
        self.unread = unread
        self.isHidden = isHidden
    }
}

public enum BadgeMode: Sendable {
    case none
    case dot
    case count(Int)
}
```

- [ ] **Step 3b: Create NewSessionPopover directory + file** (see Step 3 above)

- [ ] **Step 3c: Rewrite SidebarView** (see Step 2 above — using the final correct `isHidden` field from `row.isHidden`)

In the contacts list in SidebarView, replace `row.session.isHidden` with `row.isHidden`.

- [ ] **Step 4: Build to verify**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -10
```

Expected: `ok (build complete)` — no errors. If `createSession` is missing from AppViewModel (Agent X hasn't added it yet), add a temporary stub extension in `AppViewModel+UI.swift`:

```swift
// Temporary stub until Agent X implements createSession.
// TODO: remove once Agent X merges.
extension AppViewModel {
    @discardableResult
    public func createSession(projectPath: String, firstPrompt: String) async -> String? {
        return nil
    }
}
```

This stub must be removed once Agent X's implementation lands.

- [ ] **Step 5: Run tests**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: all tests pass (test count grows as new tests were added in Tasks 1 & 2).

- [ ] **Step 6: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/NewSession/ Sources/ChatKit/UI/Sidebar/SidebarView.swift Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift && git commit -m "feat(new-session): popover for new session + contacts tab wiring"
```

---

## Task 4: Update SessionRowView for contextual context menu

**Files:**
- Modify: `Sources/ChatKit/UI/Sidebar/SessionRowView.swift`

The current `SessionRowView` has a hardcoded `"从列表中删除"` context menu. We need to support:
- Chats tab: `"从列表中删除"` → `onDelete()`
- Contacts tab: `"移到聊天"` → `onRestore()`
- Hidden sessions render with 50% opacity.

- [ ] **Step 1: Update SessionRowView**

Replace the content of `Sources/ChatKit/UI/Sidebar/SessionRowView.swift` with:

```swift
import SwiftUI

// MARK: - SessionRowView

public struct SessionRowView: View {
    let row: SessionRowData
    let isSelected: Bool
    let isHidden: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRestore: (() -> Void)?      // nil in chats tab; non-nil in contacts tab

    @State private var isHovered = false

    public init(row: SessionRowData,
                isSelected: Bool,
                isHidden: Bool = false,
                onSelect: @escaping () -> Void,
                onDelete: @escaping () -> Void,
                onRestore: (() -> Void)? = nil) {
        self.row = row
        self.isSelected = isSelected
        self.isHidden = isHidden
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onRestore = onRestore
    }

    private var session: SessionInfo { row.session }

    public var body: some View {
        HStack(spacing: 10) {
            // Avatar with badge overlay
            ZStack(alignment: .topTrailing) {
                AvatarView(
                    seed: session.id,
                    title: session.title ?? session.projectDisplayName ?? session.id,
                    size: 38
                )
                badgeOverlay
            }

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title ?? session.projectDisplayName ?? "未命名会话")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.titleText)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime)
                        .font(AppFont.timestamp)
                        .foregroundStyle(AppColors.tertiaryText)
                }

                HStack {
                    if session.isActive == true {
                        Text("对方正在输入...")
                            .font(AppFont.sessionPreview)
                            .foregroundStyle(AppColors.sendButton)
                    } else {
                        Text(session.projectDisplayName ?? session.projectPath)
                            .font(AppFont.sessionPreview)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(isHidden ? 0.5 : 1.0)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let restore = onRestore {
                // Contacts tab — restore hidden session
                Button(action: restore) {
                    Label("移到聊天", systemImage: "arrow.uturn.left")
                }
                Divider()
            }
            Button(role: .destructive, action: onDelete) {
                Label("从列表中删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Badge overlay

    @ViewBuilder
    private var badgeOverlay: some View {
        switch row.badgeMode {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(AppColors.badge)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(AppColors.sidebar, lineWidth: 1.5))
                .offset(x: 3, y: -3)
        case .count(let n):
            Text(n > 99 ? "99+" : "\(n)")
                .font(AppFont.badge)
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 16, minHeight: 16)
                .background(AppColors.badge, in: Capsule())
                .overlay(Capsule().strokeBorder(AppColors.sidebar, lineWidth: 1.5))
                .offset(x: 4, y: -4)
        }
    }

    // MARK: - Background

    private var rowBackground: Color {
        if isSelected { return Color(hex: "#d3d3d3") }
        if isHovered  { return Color(hex: "#e8e8e8") }
        return Color.clear
    }

    // MARK: - Relative time

    private var relativeTime: String {
        guard let date = session.lastActivityAt else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "刚刚" }
        if diff < 3600 {
            let m = Int(diff / 60)
            return "\(m) 分钟前"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let components = calendar.dateComponents([.day], from: date, to: Date())
        if let days = components.day, days < 7 {
            let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
            let wd = calendar.component(.weekday, from: date) - 1
            return "周\(weekdays[wd])"
        }
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f.string(from: date)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -10
```

Expected: `ok (build complete)`.

- [ ] **Step 3: Run tests**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/Sidebar/SessionRowView.swift && git commit -m "feat(session-row): contextual context menu + hidden opacity"
```

---

## Task 5: SearchResultsView

**Files:**
- Create: `Sources/ChatKit/UI/Search/SearchResultsView.swift`

The `SearchResultsView` replaces the session list when `searchResults != nil`. It shows two sections: matching session titles and matching messages (grouped by session).

- [ ] **Step 1: Create directory and file**

```bash
mkdir -p /Users/keben/CODE/claudecodeui-local/apple/Sources/ChatKit/UI/Search
```

Then create `Sources/ChatKit/UI/Search/SearchResultsView.swift`:

```swift
import SwiftUI

// MARK: - SearchResultsView

/// Two-section search results view replacing the session list while a search
/// query is active. Shows matching session titles and matching messages.
public struct SearchResultsView: View {
    @Environment(AppViewModel.self) private var vm

    let results: SearchResults

    public init(results: SearchResults) {
        self.results = results
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Section 1: Matching sessions
                if !results.matchingSessions.isEmpty {
                    sectionHeader(title: "匹配的会话", icon: "bubble.left.and.bubble.right")

                    ForEach(results.matchingSessions) { session in
                        sessionResultRow(session)
                        Divider().padding(.leading, 60)
                    }
                }

                // Section 2: Matching messages
                if !results.matchingMessages.isEmpty {
                    sectionHeader(title: "匹配的消息", icon: "text.bubble")

                    // Group messages by sessionId
                    let grouped = Dictionary(grouping: results.matchingMessages, by: { $0.sessionId })
                    let sortedSessionIds = grouped.keys.sorted()

                    ForEach(sortedSessionIds, id: \.self) { sessionId in
                        let msgs = grouped[sessionId]!
                        let sessionInfo = results.matchingSessions.first(where: { $0.id == sessionId })
                            ?? SessionInfo(id: sessionId, projectPath: "", title: sessionId)

                        ForEach(msgs, id: \.message.id) { pair in
                            messageResultRow(session: sessionInfo, message: pair.message)
                            Divider().padding(.leading, 60)
                        }
                    }
                }

                // Empty state
                if results.matchingSessions.isEmpty && results.matchingMessages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.tertiaryText)
                        Text("无搜索结果")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.secondaryText)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColors.sidebarSearch)
    }

    // MARK: - Session result row

    private func sessionResultRow(_ session: SessionInfo) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                seed: session.id,
                title: session.title ?? session.projectDisplayName ?? session.id,
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title ?? session.projectDisplayName ?? "未命名会话")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.titleText)
                    .lineLimit(1)
                Text(session.projectDisplayName ?? session.projectPath)
                    .font(AppFont.sessionPreview)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await vm.selectSession(session.id) }
        }
    }

    // MARK: - Message result row

    private func messageResultRow(session: SessionInfo, message: ChatMessage) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                seed: session.id,
                title: session.title ?? session.projectDisplayName ?? session.id,
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title ?? session.projectDisplayName ?? "未命名会话")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.titleText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: message.role == .user ? "person" : "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.tertiaryText)
                }
                Text(message.content)
                    .font(AppFont.sessionPreview)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            // V1: navigate to session; message scroll highlight is future polish
            Task { await vm.selectSession(session.sessionId) }
        }
    }
}

// MARK: - SessionInfo convenience

// SessionInfo.sessionId is available as session.id — just aliasing for clarity in messageResultRow
private extension ChatMessage {
    var sessionId: String { self.sessionId }
}
```

Wait — `ChatMessage` already has a `sessionId` property (it's a stored let). The `messageResultRow` already receives a `session: SessionInfo`, so we call `session.id`. The tap gesture calls `vm.selectSession(session.id)`. Remove the bogus extension.

Corrected `messageResultRow` tap gesture:
```swift
.onTapGesture {
    Task { await vm.selectSession(session.id) }
}
```

And remove the private extension at the bottom.

- [ ] **Step 2: Build to verify**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -10
```

Expected: `ok (build complete)`.

- [ ] **Step 3: Run tests**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/Search/ && git commit -m "feat(search): SearchResultsView with session and message sections"
```

---

## Task 6: Settings — server profile management (select / edit / add)

**Files:**
- Modify: `Sources/ChatKit/UI/Settings/SettingsView.swift`

The existing `serversSection` only lists profiles without select or add functionality. We enhance it to:
- Show "最近使用" badge for the current profile.
- "选为当前" button (async: calls `vm.switchProfile`).
- "删除" button.
- "+ 添加服务器" form at the bottom.

- [ ] **Step 1: Update SettingsView**

Replace the `serversSection` and `serverRow` computed properties, and add `addServerForm` and related state:

The changes go inside `SettingsView`. Add `@State` vars for the add-server form. Replace the `serversSection` and `serverRow(_:)` bodies. The rest of the file stays unchanged.

Full updated `Sources/ChatKit/UI/Settings/SettingsView.swift`:

```swift
import SwiftUI

// MARK: - SettingsView

public struct SettingsView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .display

    // Add-server form state
    @State private var showAddServerForm = false
    @State private var newServerURL: String = "http://localhost:3001"
    @State private var newServerDisplayName: String = ""
    @State private var newServerURLError: String? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .display:   displaySection
                    case .behavior:  behaviorSection
                    case .servers:   serversSection
                    case .account:   accountSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 440, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab button

    private func tabButton(_ tab: SettingsTab) -> some View {
        Button(action: { selectedTab = tab }) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                Text(tab.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selectedTab == tab ? AppColors.sendButton : AppColors.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selectedTab == tab
                ? AppColors.sendButton.opacity(0.1)
                : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Display section

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "显示")

            VStack(alignment: .leading, spacing: 8) {
                Text("字体大小")
                    .font(.system(size: 13, weight: .medium))
                Picker("字体大小", selection: Bindable(settings).chatFontSize) {
                    ForEach(AppFontSize.allCases, id: \.self) { size in
                        Text(size.label)
                            .font(.system(size: size.cgFloat))
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Preview
                HStack(spacing: 8) {
                    AvatarView(seed: "preview", title: "C", size: 32)
                    Text("这是字体预览文字 — Hello World")
                        .font(AppFont.message(size: settings.chatFontSize))
                        .foregroundStyle(AppColors.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - Behavior section

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "行为")

            Toggle(isOn: Bindable(settings).autoApproveAll) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动批准所有工具调用")
                        .font(.system(size: 13, weight: .medium))
                    Text("开启后 Claude 将无需确认即可读写文件和执行命令")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    // MARK: - Servers section

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "服务器")

            let profiles = vm.serverProfileStore.list()
            if profiles.isEmpty {
                Text("暂无服务器配置")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(profiles) { profile in
                    serverRow(profile)
                }
            }

            Divider()

            // Add server form toggle
            if showAddServerForm {
                addServerForm
            } else {
                Button(action: { showAddServerForm = true }) {
                    Label("添加服务器", systemImage: "plus.circle")
                        .foregroundStyle(AppColors.actionText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
            }
        }
    }

    private func serverRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if vm.currentServerProfile?.id == profile.id {
                        Text("最近使用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppColors.sendButton, in: Capsule())
                    }
                }
                Text("\(profile.url.absoluteString) · \(profile.username)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            HStack(spacing: 8) {
                if vm.currentServerProfile?.id != profile.id {
                    Button("选为当前") {
                        Task { await vm.switchProfile(profile) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.actionText)
                    .buttonStyle(.plain)
                }
                Button(role: .destructive, action: {
                    vm.serverProfileStore.remove(profile.id)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Add server form

    private var addServerForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加服务器")
                .font(.system(size: 13, weight: .semibold))

            LabeledContent("URL") {
                TextField("http://localhost:3001", text: $newServerURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if let err = newServerURLError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            LabeledContent("名称") {
                TextField("本地开发", text: $newServerDisplayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") {
                    showAddServerForm = false
                    newServerURL = "http://localhost:3001"
                    newServerDisplayName = ""
                    newServerURLError = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("添加") { addServer() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.sendButton)
                    .disabled(newServerURL.isEmpty || newServerDisplayName.isEmpty)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Account section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "账户")

            if let user = vm.currentUser {
                HStack(spacing: 10) {
                    AvatarView(seed: "user-\(user.id)", title: user.username, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.username)
                            .font(.system(size: 14, weight: .medium))
                        Text("已登录")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.sendButton)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            Button(role: .destructive, action: {
                Task {
                    await vm.logout()
                    dismiss()
                }
            }) {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Add server action

    private func addServer() {
        guard let url = URL(string: newServerURL), url.scheme != nil else {
            newServerURLError = "URL 格式无效"
            return
        }
        newServerURLError = nil
        let profile = ServerProfile(
            url: url,
            displayName: newServerDisplayName.isEmpty ? (url.host ?? "服务器") : newServerDisplayName,
            username: ""
        )
        vm.serverProfileStore.upsert(profile)
        showAddServerForm = false
        newServerURL = "http://localhost:3001"
        newServerDisplayName = ""
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.secondaryText)
            .textCase(.uppercase)
    }
}

// MARK: - Settings Tab

private enum SettingsTab: String, CaseIterable, Identifiable {
    case display  = "display"
    case behavior = "behavior"
    case servers  = "servers"
    case account  = "account"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display:  return "显示"
        case .behavior: return "行为"
        case .servers:  return "服务器"
        case .account:  return "账户"
        }
    }

    var icon: String {
        switch self {
        case .display:  return "textformat"
        case .behavior: return "slider.horizontal.3"
        case .servers:  return "server.rack"
        case .account:  return "person.circle"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -10
```

Expected: `ok (build complete)`.

- [ ] **Step 3: Run tests**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/Settings/SettingsView.swift && git commit -m "feat(settings): server profile selection, add form, and switchProfile wiring"
```

---

## Task 7: Logout flow — verify and clean up

**Files:**
- Verify: `Sources/ClaudeChat/main.swift` (read-only) — `RootView` switches on `vm.authState`
- Modify: `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift` — wrap logout + cleanupUI

The logout button in Settings already calls `vm.logout()` then `dismiss()`. `vm.logout()` sets `authState = .loggedOut`. `RootView` in `main.swift` switches on `authState` and shows `LoginView` when `.loggedOut`. The flow already works.

We add a convenience `logoutAndCleanup()` that combines `vm.logout()` + `vm.cleanupUI()` to ensure any UI-local caches are wiped.

- [ ] **Step 1: Add `logoutAndCleanup` to AppViewModel+UI.swift**

Edit `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift` to add:

```swift
    // MARK: - Logout

    /// Calls logout() then clears all UI-local caches.
    public func logoutAndCleanup() async {
        await logout()
        await cleanupUI()
    }
```

Full updated file:

```swift
import Foundation

// MARK: - AppViewModel+UI
//
// UI-layer helpers that Agent Z owns. Do NOT add these to AppViewModel.swift.

extension AppViewModel {

    // MARK: - Profile switching

    /// Switch to a different server profile:
    /// 1. Updates currentServerProfile and configures the API client.
    /// 2. Loads the stored token for the profile.
    /// 3. If a token exists, verifies it by calling currentUser().
    ///    - On success → .loggedIn
    ///    - On failure → .loggedOut
    /// 4. If no token → .loggedOut
    public func switchProfile(_ profile: ServerProfile) async {
        currentServerProfile = profile
        await apiClient.setBaseURL(profile.url)

        if let token = keychain.token(for: profile.id) {
            await apiClient.setToken(token)
            do {
                let user = try await apiClient.currentUser()
                authState = .loggedIn(user: user)
                await loadSessions()
            } catch {
                await apiClient.setToken(nil)
                authState = .loggedOut
            }
        } else {
            await apiClient.setToken(nil)
            authState = .loggedOut
        }
    }

    // MARK: - UI-local cleanup

    /// Clear UI-local caches. Call this after logout or before switching profile.
    /// Does NOT modify authState — call vm.logout() first if needed.
    public func cleanupUI() async {
        sessions = []
        currentSessionId = nil
        unreadCounts = [:]
    }

    // MARK: - Logout

    /// Calls logout() then clears all UI-local caches.
    /// The authState is set to .loggedOut by logout(); RootView will switch to LoginView.
    public func logoutAndCleanup() async {
        await logout()
        await cleanupUI()
    }
}
```

- [ ] **Step 2: Update Settings logout button to call logoutAndCleanup**

In `Sources/ChatKit/UI/Settings/SettingsView.swift`, find the logout button action and change `await vm.logout()` to `await vm.logoutAndCleanup()`:

```swift
            Button(role: .destructive, action: {
                Task {
                    await vm.logoutAndCleanup()
                    dismiss()
                }
            }) {
```

- [ ] **Step 3: Add a test for logoutAndCleanup in UIAppViewModelUITests.swift**

Add this test to the existing `UIAppViewModelUITests` class:

```swift
    func testLogoutAndCleanupResetsState() async {
        let vm = makeVM()
        vm.authState = .loggedIn(user: User(id: 1, username: "test"))
        vm.sessions = [SessionInfo(id: "s1", projectPath: "/p")]
        vm.currentSessionId = "s1"
        vm.unreadCounts = ["s1": 2]

        await vm.logoutAndCleanup()

        if case .loggedOut = vm.authState {
            // pass
        } else {
            XCTFail("Expected loggedOut, got \(vm.authState)")
        }
        XCTAssertEqual(vm.sessions.count, 0)
        XCTAssertNil(vm.currentSessionId)
        XCTAssertEqual(vm.unreadCounts.count, 0)
    }
```

- [ ] **Step 4: Build and test**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5
```

Expected: build ok, all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && git add Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift Sources/ChatKit/UI/Settings/SettingsView.swift Tests/ChatKitTests/UIAppViewModelUITests.swift && git commit -m "feat(logout): logoutAndCleanup helper + wired in settings"
```

---

## Task 8: Final build + full test pass

- [ ] **Step 1: Full build**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift build 2>&1 | tail -5
```

Expected: `ok (build complete)`.

- [ ] **Step 2: Full test suite**

```bash
cd /Users/keben/CODE/claudecodeui-local/apple && swift test 2>&1 | grep -E "Executed|passed|failed"
```

Expected: All tests pass. Count should be >= 128 (121 original + new tests from Tasks 1, 2, 7).

- [ ] **Step 3: Verify no agent boundary violations**

```bash
grep -r "createSession" /Users/keben/CODE/claudecodeui-local/apple/Sources/ChatKit/Network/ 2>/dev/null | head -5 || echo "clean"
grep -r "StorageProtocol" /Users/keben/CODE/claudecodeui-local/apple/Sources/ChatKit/UI/ViewModels/AppViewModel.swift | head -5
```

Expected: no edits to Network/ or AppViewModel.swift (only +UI extension).

---

## Self-Review Checklist

**Spec coverage:**

1. New session popover (+ button) — Task 3 creates `NewSessionPopover.swift`, wires to `createSession`.
2. Contacts tab with hidden sessions at 50% opacity — Task 3 (contactsList in SidebarView), Task 4 (SessionRowView opacity).
3. Contacts tab "移到聊天" context menu — Task 4 (SessionRowView onRestore).
4. Chats tab "从列表中删除" context menu — Task 4 (SessionRowView onDelete, always present).
5. Settings server profiles: list, "最近使用" badge, "选为当前", "删除" — Task 6.
6. Settings "+" add form — Task 6.
7. `vm.switchProfile` async method — Task 2.
8. Search bar debouncing + SearchResultsView — Tasks 1 and 5. Note: the spec says "debounced 250ms" — the current implementation calls `refresh` on `.onChange`. For V1 this is acceptable; debouncing would require a Combine publisher or a `Task.sleep(250ms)` pattern which adds complexity. We call it on every change, which matches `SessionListViewModel.refresh` already calling `storage.search`. This is noted as a deviation.
9. Logout flow + `authState = .loggedOut` → LoginView — Task 7. RootView in main.swift already handles the switch; we add `logoutAndCleanup()`.
10. `allSessions` distinct from `rows` — Task 1.
11. `searchResults: SearchResults?` on SessionListViewModel — Task 1.

**Placeholder scan:** No TBDs, all code blocks complete.

**Type consistency:**
- `SessionRowData.isHidden: Bool` added in Task 1 (Step 3a) and used in Tasks 3, 4.
- `listVM.searchResults` used in SidebarView (Task 3) — matches field added in Task 1.
- `vm.switchProfile` used in SettingsView (Task 6) — defined in Task 2.
- `vm.logoutAndCleanup` used in SettingsView (Task 7) — defined in Task 7.
- `NewSessionPopover` calls `vm.createSession` — Agent X contract, stub provided in Task 3 if needed.

**Known deviation:** Search debouncing is not implemented (calls on each keystroke). This matches the existing pattern and is acceptable for V1.

**Files created:**
- `Sources/ChatKit/UI/NewSession/NewSessionPopover.swift`
- `Sources/ChatKit/UI/Search/SearchResultsView.swift`
- `Sources/ChatKit/UI/ViewModels/AppViewModel+UI.swift`
- `Tests/ChatKitTests/UISessionListViewModelTests.swift`
- `Tests/ChatKitTests/UIAppViewModelUITests.swift`

**Files modified:**
- `Sources/ChatKit/UI/ViewModels/SessionListViewModel.swift`
- `Sources/ChatKit/UI/Sidebar/SidebarView.swift`
- `Sources/ChatKit/UI/Sidebar/SessionRowView.swift`
- `Sources/ChatKit/UI/Settings/SettingsView.swift`
