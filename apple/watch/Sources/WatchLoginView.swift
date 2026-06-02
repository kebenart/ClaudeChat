import SwiftUI
import ChatKit

/// Minimal watch login: server URL + username + password, then a 6-digit TOTP
/// code if the account has 2FA. Mirrors the iOS LoginView/TOTPView flow but
/// trimmed for the small screen (Scribble/Dictation input, no keyboardType).
struct WatchLoginView: View {
    @Environment(WatchAppModel.self) private var model
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        Form {
            if model.pendingTotpToken == nil {
                passwordStep
            } else {
                totpStep
            }
        }
        .navigationTitle("登录")
        .onAppear { if serverURL.isEmpty { serverURL = model.serverURLString } }
    }

    @ViewBuilder private var passwordStep: some View {
        Section("服务器") {
            TextField("https://…", text: $serverURL).font(.system(size: 13))
        }
        Section("账号") {
            TextField("用户名", text: $username).font(.system(size: 14))
            SecureField("密码", text: $password).font(.system(size: 14))
        }
        if let err = model.loginError {
            Text(err).font(.system(size: 12)).foregroundStyle(.red)
        }
        Section {
            Button(action: submitPassword) {
                if model.isLoggingIn {
                    HStack { ProgressView(); Text("登录中…") }
                } else {
                    Text("登录").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
            }
            .disabled(model.isLoggingIn
                      || serverURL.trimmingCharacters(in: .whitespaces).isEmpty
                      || username.isEmpty || password.isEmpty)
        }
    }

    @ViewBuilder private var totpStep: some View {
        Section("两步验证") {
            TextField("6 位验证码", text: $code)
                .font(.system(size: 18, design: .monospaced))
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { code = digits }
                    if digits.count == 6 { Task { _ = await model.submitTOTP(code: digits) } }
                }
        }
        if let err = model.loginError {
            Text(err).font(.system(size: 12)).foregroundStyle(.red)
        }
        Section {
            Button("验证") { Task { _ = await model.submitTOTP(code: code) } }
                .disabled(model.isLoggingIn || code.count != 6)
            Button("返回") { code = ""; model.cancelLogin() }
                .foregroundStyle(.secondary)
        }
    }

    private func submitPassword() {
        model.serverURLString = serverURL.trimmingCharacters(in: .whitespaces)
        Task { _ = await model.login(username: username, password: password) }
    }
}
