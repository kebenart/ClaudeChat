import ChatKit
import SwiftUI

// MARK: - SessionRowView

public struct SessionRowView: View {
    @Environment(AppViewModel.self) private var vm
    let row: SessionRowData
    let isSelected: Bool
    let isHidden: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRestore: (() -> Void)?      // nil in chats tab; non-nil in contacts tab
    let isFolded: Bool
    let onFold: (() -> Void)?
    let onBlacklist: (() -> Void)?

    @State private var isHovered = false
    @State private var showRenameSheet = false
    @State private var noteDraft = ""

    public init(row: SessionRowData,
                isSelected: Bool,
                isHidden: Bool = false,
                onSelect: @escaping () -> Void,
                onDelete: @escaping () -> Void,
                onRestore: (() -> Void)? = nil,
                isFolded: Bool = false,
                onFold: (() -> Void)? = nil,
                onBlacklist: (() -> Void)? = nil) {
        self.row = row
        self.isSelected = isSelected
        self.isHidden = isHidden
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onRestore = onRestore
        self.isFolded = isFolded
        self.onFold = onFold
        self.onBlacklist = onBlacklist
    }

    private var session: SessionInfo { row.session }

    public var body: some View {
        HStack(spacing: 10) {
            // Avatar with badge overlay
            ZStack(alignment: .topTrailing) {
                AvatarView(
                    seed: session.id,
                    title: session.displayName,
                    size: 38
                )
                .overlay(alignment: .bottomTrailing) {
                    // Green online dot when Claude is live/active for this session.
                    if session.isActive == true {
                        Circle()
                            .fill(Color(hex: "#07c160"))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(AppColors.sidebar, lineWidth: 2))
                            .offset(x: 1, y: 1)
                    }
                }
                badgeOverlay
            }

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppColors.sendButton)
                    }
                    Text(session.displayName.clampedNickname)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.titleText)
                        .lineLimit(1)
                    if session.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppColors.tertiaryText)
                    }
                    Spacer()
                    Text(relativeTime)
                        .font(AppFont.timestamp)
                        .foregroundStyle(AppColors.tertiaryText)
                }

                // Second line: typing indicator OR latest message preview.
                // No project path here — that lives in the session info panel.
                if session.isActive == true {
                    Text("对方正在输入...")
                        .font(AppFont.sessionPreview)
                        .foregroundStyle(AppColors.sendButton)
                } else if let preview = session.latestMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(AppFont.sessionPreview)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            // Pin / unpin
            Button {
                Task { await vm.setPinned(sessionId: session.id, !session.isPinned) }
            } label: {
                Label(session.isPinned ? "取消置顶" : "置顶聊天",
                      systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            // Mute / unmute
            Button {
                Task { await vm.setMuted(sessionId: session.id, !session.isMuted) }
            } label: {
                Label(session.isMuted ? "取消静音" : "消息免打扰",
                      systemImage: session.isMuted ? "bell" : "bell.slash")
            }
            // Mark read
            if session.unreadCount > 0 {
                Button {
                    Task { await vm.markRead(sessionId: session.id) }
                } label: {
                    Label("标为已读", systemImage: "envelope.open")
                }
            }
            // Rename (note)
            Button {
                noteDraft = session.note ?? ""
                showRenameSheet = true
            } label: {
                Label("设置备注名", systemImage: "pencil")
            }

            if let onFold {
                Button(action: onFold) {
                    Label(isFolded ? "取消折叠" : "折叠聊天", systemImage: "rectangle.stack")
                }
            }

            Divider()

            if let restore = onRestore {
                Button(action: restore) {
                    Label("移到聊天", systemImage: "arrow.uturn.left")
                }
            }
            if let onBlacklist {
                Button(role: .destructive, action: onBlacklist) {
                    Label("拉黑此项目路径", systemImage: "nosign")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除聊天", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("备注名")
                .font(.system(size: 14, weight: .semibold))
            TextField("给这个会话起个名字", text: $noteDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack(spacing: 12) {
                Button("取消") { showRenameSheet = false }
                    .buttonStyle(.bordered)
                Button("保存") {
                    let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        // Routes through the IM hub so the note syncs cross-device.
                        await vm.setNote(sessionId: session.id,
                                         trimmed.isEmpty ? nil : trimmed)
                    }
                    showRenameSheet = false
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.sendButton)
            }
        }
        .padding(24)
        .frame(width: 360)
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
        if isSelected { return AppColors.rowSelected }
        if isHovered  { return AppColors.rowHovered }
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
