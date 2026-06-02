import SwiftUI
import ChatKit

/// A contact = a unique contactId across all conversations.
private struct Contact: Identifiable, Hashable {
    let id: String        // contactId (or "unknown" for nil)
    let displayName: String
    let conversations: [ImConversationDTO]
}

struct ContactsView: View {
    @Environment(IOSAppModel.self) private var model

    private var allContacts: [Contact] {
        // Group conversations by contactId; sort by most-recent activity.
        // Blacklisted paths are excluded entirely.
        var groups: [String: [ImConversationDTO]] = [:]
        for conv in model.conversations {
            if model.isBlacklisted(conv) { continue }
            let key = conv.contactId ?? "unknown"
            groups[key, default: []].append(conv)
        }
        return groups
            .map { key, convs in
                Contact(
                    id: key,
                    displayName: key == "unknown" ? "未知联系人" : (key.components(separatedBy: "/").last ?? key),
                    conversations: convs.sorted { $0.lastActivityAt > $1.lastActivityAt }
                )
            }
            .sorted { ($0.conversations.first?.lastActivityAt ?? 0) > ($1.conversations.first?.lastActivityAt ?? 0) }
    }

    private var contacts: [Contact] { allContacts }

    var body: some View {
        NavigationStack {
            List {
                ForEach(contacts) { contact in contactLink(contact) }
            }
            .listStyle(.plain)
            .navigationTitle("通讯录")
            .overlay {
                if allContacts.isEmpty {
                    ContentUnavailableView("暂无联系人", systemImage: "person.2")
                }
            }
        }
    }

    @ViewBuilder private func contactLink(_ contact: Contact) -> some View {
        // Navigation in the background so the List omits its `>` chevron.
        contactRow(contact)
            .contentShape(Rectangle())
            .background(
                NavigationLink {
                    ContactConversationsView(contact: contact).environment(model)
                } label: { EmptyView() }.opacity(0)
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if contact.id != "unknown" {
                Button(role: .destructive) {
                    withAnimation { model.setBlacklisted(contact.id, true) }
                } label: { Label("拉黑", systemImage: "nosign") }
            }
        }
    }

    @ViewBuilder private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            IOSAvatar(seed: contact.id, title: contact.displayName, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName.clampedNickname)
                    .font(.system(size: 16, weight: .medium))
                Text("\(contact.conversations.count) 个对话")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Contact conversation list

private struct ContactConversationsView: View {
    let contact: Contact
    @Environment(IOSAppModel.self) private var model

    var body: some View {
        List(contact.conversations) { conv in
            convRow(conv)
                .contentShape(Rectangle())
                .background(
                    NavigationLink {
                        ChatDetailView(conversation: conv)
                            .environment(model)
                    } label: { EmptyView() }.opacity(0)
                )
        }
        .listStyle(.plain)
        .navigationTitle(contact.displayName.clampedNickname)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func convRow(_ conv: ImConversationDTO) -> some View {
        HStack(spacing: 12) {
            IOSAvatar(seed: conv.id, title: conv.title ?? "C", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text((conv.title ?? String(conv.id.prefix(8))).clampedNickname)
                    .font(.system(size: 15, weight: .medium))
                if let preview = conv.lastMessagePreview {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let n = model.unread[conv.id], n > 0 {
                Text("\(n)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
            }
        }
    }
}
