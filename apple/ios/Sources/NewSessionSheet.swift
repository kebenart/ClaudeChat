import SwiftUI
import ChatKit

// MARK: - NewSessionSheet ("发起会话")
//
// Pick a contact (project) and type a first message to bootstrap a fresh chat.
// Mirrors the web WeChatNewSessionPopover. The server assigns the session id on
// the first send; `onCreated` fires with the new conversation id so the caller
// can navigate into it. Also offers inline "添加联系人" (create a project).

struct NewSessionSheet: View {
    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Called with the new conversation id once the session is created.
    let onCreated: (String) -> Void

    @State private var projects: [ProjectInfo] = []
    @State private var search = ""
    @State private var selected: ProjectInfo?
    @State private var firstMessage = ""
    @State private var creating = false
    @State private var errorText: String?

    // Add-contact alert
    @State private var addingContact = false
    @State private var newPath = ""
    @State private var newName = ""

    private var filtered: [ProjectInfo] {
        let usable = projects.filter { !($0.fullPath ?? $0.path).isEmpty }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return usable }
        return usable.filter {
            "\($0.displayName) \($0.fullPath ?? $0.path)".lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button { addingContact = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(WC.accent, in: RoundedRectangle(cornerRadius: 8))
                        Text("添加联系人").font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()

                List(filtered, selection: Binding(get: { selected?.id }, set: { id in
                    selected = filtered.first { $0.id == id }
                })) { p in
                    Button { selected = p } label: { projectRow(p) }
                        .buttonStyle(.plain)
                        .listRowBackground(selected?.id == p.id ? WC.accent.opacity(0.12) : Color(.systemBackground))
                }
                .listStyle(.plain)
                .overlay { if filtered.isEmpty { ContentUnavailableView("暂无联系人，先添加一个", systemImage: "person.2") } }

                Divider()
                composeBar
            }
            .navigationTitle("发起会话")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索联系人")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
            .alert("添加联系人", isPresented: $addingContact) {
                TextField("工作目录绝对路径，如 /Users/you/proj", text: $newPath)
                TextField("备注名（可选）", text: $newName)
                Button("创建") { Task { await addContact() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("输入一个已存在的目录路径作为新联系人")
            }
            .alert("创建失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
            .task { projects = await model.projects() }
        }
    }

    @ViewBuilder private func projectRow(_ p: ProjectInfo) -> some View {
        HStack(spacing: 12) {
            IOSAvatar(seed: p.id, title: p.displayName, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(p.fullPath ?? p.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected?.id == p.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(WC.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private var composeBar: some View {
        HStack(spacing: 8) {
            TextField(selected == nil ? "先选择一个联系人" : "对 \(selected!.displayName.clampedNickname) 说…",
                      text: $firstMessage, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .disabled(selected == nil || creating)
            Button { Task { await create() } } label: {
                if creating { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(canSend ? WC.accent : Color.secondary)
                        .imageScale(.large)
                }
            }
            .disabled(!canSend || creating)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var canSend: Bool {
        selected != nil && !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addContact() async {
        let path = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        if let created = await model.createContact(path: path, customName: newName) {
            projects = await model.projects()
            selected = projects.first { $0.id == created.id } ?? created
            newPath = ""; newName = ""
        } else {
            errorText = "无法创建联系人，请确认路径存在且可访问。"
        }
    }

    private func create() async {
        guard let project = selected, canSend else { return }
        creating = true
        let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let convId = await model.startNewSession(projectPath: project.fullPath ?? project.path, firstPrompt: text)
        creating = false
        if let convId {
            dismiss()
            onCreated(convId)
        } else {
            errorText = "会话创建超时。请确认后端在运行、路径有效。"
        }
    }
}
