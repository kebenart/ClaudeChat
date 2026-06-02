import ChatKit
import SwiftUI

// MARK: - LoginView

public struct LoginView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showServerPicker = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Logo / brand
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColors.sendButton)
                    Text("Claude Chat")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColors.primaryText)
                }

                // Form
                VStack(spacing: 12) {
                    serverRow

                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await doLogin() } }

                    if let err = vm.loginError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: { Task { await doLogin() } }) {
                        if vm.isLoggingIn {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("登录")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.sendButton)
                    .disabled(vm.isLoggingIn || username.isEmpty || password.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
                .frame(width: 300)
            }

            Spacer()

            Text("版本 0.0.1-scaffold")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.tertiaryText)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showServerPicker) {
            ServerPickerView()
                .environment(vm)
        }
    }

    // MARK: - Server row

    private var serverRow: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 16)
            Text(vm.currentServerProfile?.displayName ?? "未选择服务器")
                .font(.system(size: 12))
                .foregroundStyle(vm.currentServerProfile == nil ? AppColors.tertiaryText : AppColors.primaryText)
            Spacer()
            Button("切换") { showServerPicker = true }
                .font(.system(size: 12))
                .foregroundStyle(AppColors.actionText)
                .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func doLogin() async {
        await vm.login(username: username, password: password)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    LoginView()
        .environment(AppViewModel(
            apiClient: StubAPIClient(),
            socket: StubChatSocket(),
            storage: StubStorage(),
            keychain: StubKeychain(),
            serverProfileStore: StubServerProfileStore()
        ))
        .environment(AppSettings())
        .frame(width: 480, height: 400)
}
#endif
