import ChatKit
import SwiftUI

// MARK: - ServerPickerView

public struct ServerPickerView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var showAddForm = false
    @State private var newURL: String = "http://localhost:3000"
    @State private var newDisplayName: String = ""
    @State private var newUsername: String = ""
    @State private var urlError: String?

    private var profiles: [ServerProfile] {
        vm.serverProfileStore.list()
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("选择服务器")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Server list
            List {
                ForEach(profiles) { profile in
                    serverRow(profile)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 120)

            Divider()

            // Add server section
            if showAddForm {
                addServerForm
            } else {
                Button(action: { showAddForm = true }) {
                    Label("添加服务器", systemImage: "plus.circle")
                }
                .padding(12)
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.actionText)
            }
        }
        .frame(width: 380, height: showAddForm ? 480 : 300)
    }

    // MARK: - Server row

    private func serverRow(_ profile: ServerProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(profile.url.absoluteString) · \(profile.username)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            if vm.currentServerProfile?.id == profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.sendButton)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectProfile(profile)
        }
        .contextMenu {
            Button(role: .destructive) {
                vm.serverProfileStore.remove(profile.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Add server form

    private var addServerForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("添加服务器")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)

            VStack(spacing: 10) {
                LabeledContent("URL") {
                    TextField("http://localhost:3000", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                if let err = urlError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }
                LabeledContent("名称") {
                    TextField("本地开发", text: $newDisplayName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("用户名") {
                    TextField("admin", text: $newUsername)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }
            .padding(.horizontal, 16)

            HStack {
                Button("取消") {
                    showAddForm = false
                    resetForm()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("添加") { addServer() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.sendButton)
                    .disabled(newURL.isEmpty || newDisplayName.isEmpty || newUsername.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Actions

    private func selectProfile(_ profile: ServerProfile) {
        vm.currentServerProfile = profile
        Task { await vm.apiClient.setBaseURL(profile.url) }
        // Mark as most recently used
        var updated = profile
        updated = ServerProfile(id: profile.id, url: profile.url,
                                displayName: profile.displayName,
                                username: profile.username, lastUsedAt: Date())
        vm.serverProfileStore.upsert(updated)
        dismiss()
    }

    private func addServer() {
        guard let url = URL(string: newURL), url.scheme != nil else {
            urlError = "URL 格式无效"
            return
        }
        urlError = nil
        let profile = ServerProfile(
            url: url,
            displayName: newDisplayName.isEmpty ? url.host ?? "服务器" : newDisplayName,
            username: newUsername.isEmpty ? "admin" : newUsername
        )
        vm.serverProfileStore.upsert(profile)
        selectProfile(profile)
        resetForm()
        showAddForm = false
    }

    private func resetForm() {
        newURL = "http://localhost:3000"
        newDisplayName = ""
        newUsername = ""
        urlError = nil
    }
}
