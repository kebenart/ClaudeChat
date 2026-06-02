import ChatKit
import SwiftUI

// MARK: - Rail Tab
//
// Mirrors the four WeChat-for-Mac tabs:
//   微信 (chats)  → recent conversations
//   通讯录 (contacts) → all sessions as a contact book, alphabetized
//   发现 (discover) → Claude tools / skills / commands browser
//   我 (me) → user profile card + settings groups

public enum RailTab: Equatable, Sendable, CaseIterable {
    case chats
    case contacts
    case discover
    case me
}

// MARK: - RailView

public struct RailView: View {
    @Environment(AppViewModel.self) private var vm
    @Binding var selection: RailTab

    public init(selection: Binding<RailTab>) {
        self._selection = selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            // "Me" avatar at top — tapping it jumps to the Me tab,
            // matching the WeChat-Mac affordance.
            Button(action: { selection = .me }) {
                meAvatar
            }
            .buttonStyle(.plain)
            .padding(.top, 36)
            .padding(.bottom, 16)

            railIcon(systemName: "bubble.left.and.bubble.right",
                     tab: .chats,
                     badge: vm.totalUnread)

            railIcon(systemName: "person.2",
                     tab: .contacts,
                     badge: 0)

            railIcon(systemName: "safari",
                     tab: .discover,
                     badge: 0)

            railIcon(systemName: "person.crop.circle",
                     tab: .me,
                     badge: 0)

            Spacer()
        }
        .frame(width: 64)
        .background(AppColors.rail)
    }

    // MARK: - Me avatar

    private var meAvatar: some View {
        let user = vm.currentUser
        let seed = user.map { "user-\($0.id)" } ?? "me"
        let title = user?.username ?? "Me"
        return AvatarView(seed: seed, title: title, size: 36)
    }

    // MARK: - Rail icon button

    private func railIcon(systemName: String, tab: RailTab, badge: Int) -> some View {
        Button(action: { selection = tab }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 22))
                    .foregroundStyle(selection == tab ? AppColors.railIconActive : AppColors.railIcon)
                    .frame(width: 36, height: 36)
                    .background(
                        selection == tab
                        ? AppColors.railActiveBackground
                        : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )

                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(AppFont.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(AppColors.badge, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppColors.rail, lineWidth: 1.5))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}
