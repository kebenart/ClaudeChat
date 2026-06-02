import ChatKit
import SwiftUI

// MARK: - SidebarView

public struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm
    let tab: RailTab
    let listVM: SessionListViewModel

    @State private var showNewSession = false
    @State private var collapsedGroups: Set<String> = []
    @State private var isRefreshing = false

    public init(tab: RailTab, listVM: SessionListViewModel) {
        self.tab = tab
        self.listVM = listVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Only chats + contacts have the search/new-session header.
            if tab == .chats || tab == .contacts {
                sidebarHeader
                Divider()
            }
            content
        }
        .background(AppColors.sidebar)
        .task(id: "\(tab)-\((vm.imController?.conversations.count ?? 0))-\(vm.mergedUnreadCounts.description)-\(vm.metaRevision)-\(vm.imController?.syncRevision ?? 0)") {
            // Stage 2: the chats list is now IM-hub-driven (ImConversationDTO),
            // matching iOS/web. Contacts still uses the provider sessions.
            await listVM.refresh(conversations: vm.imController?.conversations ?? [],
                                 unreadCounts: vm.mergedUnreadCounts,
                                 blacklistedPaths: vm.blacklistedPaths,
                                 liveSessionIds: vm.liveSessionIds)
            if tab == .contacts {
                await listVM.refreshAll(conversations: vm.imController?.conversations ?? [], liveSessionIds: vm.liveSessionIds)
            }
        }
    }

    // MARK: - Sidebar header (search bar + new session button)

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
                        Task { await listVM.refresh(conversations: vm.imController?.conversations ?? [],
                                                    unreadCounts: vm.mergedUnreadCounts,
                                                    blacklistedPaths: vm.blacklistedPaths,
                                                    liveSessionIds: vm.liveSessionIds) }
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
            .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(AppColors.border, lineWidth: 0.5))

            // "New session" / "Add contact" button on both Chats and Contacts.
            if tab == .chats || tab == .contacts {
                Button(action: { showNewSession = true }) {
                    Image(systemName: tab == .contacts ? "person.badge.plus" : "square.and.pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(AppColors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(tab == .contacts ? "新增联系人 (新会话)" : "新建会话")
                .popover(isPresented: $showNewSession, arrowEdge: .bottom) {
                    NewSessionPopover()
                        .environment(vm)
                }
            }
            // Manual refresh: re-pull provider sessions + the IM /sync.
            Button(action: {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task { await vm.manualRefresh(); isRefreshing = false }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(AppColors.claudeBubble, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(AppColors.border, lineWidth: 0.5))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: isRefreshing)
            }
            .buttonStyle(.plain)
            .help("刷新")
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
        case .discover:
            DiscoverSidebar()
                .environment(vm)
        case .me:
            MeSidebar(listVM: listVM)
                .environment(vm)
        }
    }

    // MARK: - Chats list

    private var chatsList: some View {
        let mainRows = listVM.rows.filter { !listVM.isFolded($0.id) }
        let foldedRows = listVM.rows.filter { listVM.isFolded($0.id) }
        return ScrollView {
            LazyVStack(spacing: 0) {
                if !foldedRows.isEmpty {
                    Button {
                        if collapsedGroups.contains("__folded__") { collapsedGroups.remove("__folded__") }
                        else { collapsedGroups.insert("__folded__") }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.stack").font(.system(size: 12))
                                .foregroundStyle(AppColors.secondaryText)
                            Text("折叠的聊天").font(.system(size: 12)).foregroundStyle(AppColors.titleText)
                            Text("\(foldedRows.count)").font(.system(size: 11)).foregroundStyle(AppColors.secondaryText)
                            Spacer()
                            Image(systemName: collapsedGroups.contains("__folded__") ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10)).foregroundStyle(AppColors.tertiaryText)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !collapsedGroups.contains("__folded__") {
                        ForEach(foldedRows) { row in
                            chatRow(row, folded: true)
                            Divider().padding(.leading, 60)
                        }
                    }
                    Divider()
                }
                ForEach(mainRows) { row in
                    chatRow(row, folded: false)
                    Divider()
                        .padding(.leading, 60)
                }
                if listVM.rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: listVM.isSearching
                              ? "magnifyingglass"
                              : "bubble.left.and.bubble.right")
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

    @ViewBuilder
    private func chatRow(_ row: SessionRowData, folded: Bool) -> some View {
        SessionRowView(
            row: row,
            isSelected: vm.currentSessionId == row.id,
            isHidden: false,
            onSelect: { Task { await vm.selectSession(row.id) } },
            onDelete: { Task { await vm.deleteConversation(sessionId: row.id) } },
            onRestore: nil,
            isFolded: folded,
            onFold: { Task { await vm.setFolded(sessionId: row.id, !folded) } },
            onBlacklist: { Task { await vm.setBlacklisted(row.session.projectPath, true) } }
        )
    }

    // MARK: - Contacts list (compact: avatar + nickname, grouped by project)

    private var contactsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
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
                } else {
                    ForEach(contactGroups, id: \.project) { group in
                        Section {
                            if !collapsedGroups.contains(group.project) {
                                ForEach(group.rows) { row in
                                    CompactContactRow(
                                        row: row,
                                        isSelected: vm.currentSessionId == row.id
                                    ) {
                                        Task { await vm.selectSession(row.id) }
                                    } onRestore: {
                                        Task { await vm.restoreSession(row.id) }
                                    } onDelete: {
                                        Task { await vm.softDeleteSession(row.id) }
                                    }
                                }
                            }
                        } header: {
                            ContactGroupHeader(
                                project: group.project,
                                count: group.rows.count,
                                isCollapsed: collapsedGroups.contains(group.project)
                            ) {
                                if collapsedGroups.contains(group.project) {
                                    collapsedGroups.remove(group.project)
                                } else {
                                    collapsedGroups.insert(group.project)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Sessions grouped by project display name. Hidden sessions are included
    /// (their row uses 50% opacity in `CompactContactRow`).
    private var contactGroups: [(project: String, rows: [SessionRowData])] {
        let visible = listVM.allSessions.filter { !vm.isPathBlacklisted($0.session.projectPath) }
        let dict = Dictionary(grouping: visible) { row -> String in
            let name = row.session.projectDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
            return "未分组"
        }
        return dict
            .map { (project: $0.key, rows: $0.value) }
            .sorted { $0.project < $1.project }
    }
}

// MARK: - Compact contact row

private struct CompactContactRow: View {
    let row: SessionRowData
    let isSelected: Bool
    let onSelect: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AvatarView(
                    seed: row.session.id,
                    title: row.session.displayName,
                    size: 32
                )
                Text(row.session.displayName.clampedNickname)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.titleText)
                    .lineLimit(1)
                Spacer()
                if row.session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppColors.sendButton)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(row.isHidden ? 0.5 : 1.0)
            .background(isSelected ? AppColors.sidebarDivider : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if row.isHidden {
                Button { onRestore() } label: { Label("移到聊天", systemImage: "tray.and.arrow.up") }
            } else {
                Button(role: .destructive) { onDelete() } label: {
                    Label("从列表中删除", systemImage: "eye.slash")
                }
            }
        }
    }
}

private struct ContactGroupHeader: View {
    let project: String
    let count: Int
    var isCollapsed: Bool = false
    var onToggle: () -> Void = {}

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.tertiaryText)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(project)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppColors.secondaryText)
                    .textCase(.uppercase)
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(AppColors.sidebar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
