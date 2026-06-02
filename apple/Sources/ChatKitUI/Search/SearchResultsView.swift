import ChatKit
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
                    let grouped = Dictionary(
                        grouping: results.matchingMessages,
                        by: { $0.sessionId }
                    )
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
            Task { await vm.selectSession(session.id) }
        }
    }
}
