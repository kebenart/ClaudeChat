import ChatKit
import SwiftUI

// MARK: - TOTPView

public struct TOTPView: View {
    @Environment(AppViewModel.self) private var vm
    let totpToken: String

    @State private var code: String = ""
    @FocusState private var focused: Bool

    public init(totpToken: String) {
        self.totpToken = totpToken
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColors.sendButton)
                    Text("双因素验证")
                        .font(.system(size: 22, weight: .semibold))
                    Text("请输入验证器 App 中显示的 6 位数字验证码")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("000000", text: $code)
                        .font(.system(size: 26, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onChange(of: code) { _, new in
                            let filtered = new.filter(\.isNumber)
                            if filtered != new || new.count > 6 {
                                code = String(filtered.prefix(6))
                            }
                        }
                        .onSubmit { Task { await submit() } }
                        .padding(.horizontal, 12)
                        .frame(width: 220, height: 48)
                        .background(Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                        )

                    if let err = vm.loginError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button("返回") {
                            withAnimation { vm.authState = .loggedOut }
                        }
                        .buttonStyle(.bordered)

                        Button(action: { Task { await submit() } }) {
                            if vm.isLoggingIn {
                                ProgressView().controlSize(.small).frame(width: 60)
                            } else {
                                Text("验证").frame(width: 60)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.sendButton)
                        .disabled(vm.isLoggingIn || code.count != 6)
                    }
                    .frame(width: 200)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }

    private func submit() async {
        await vm.submitTOTP(totpToken: totpToken, code: code)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    TOTPView(totpToken: "preview-totp-token")
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
