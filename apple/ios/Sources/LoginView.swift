import SwiftUI
import ChatKit

struct LoginView: View {
    @Environment(IOSAppModel.self) private var model
    @State private var serverURL: String = "http://127.0.0.1:3001"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case serverURL, username, password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("http://127.0.0.1:3001", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .serverURL)
                }
                Section("账号") {
                    TextField("用户名", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                }
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.system(size: 14))
                    }
                }
                Section {
                    Button(action: { Task { await doLogin() } }) {
                        if isLoading {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("登录中...")
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("登录")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isLoading || serverURL.isEmpty)
                }
            }
            .navigationTitle("连接到服务器")
            .navigationBarTitleDisplayMode(.large)
        }
        // Show TOTP sheet when needed
        .sheet(isPresented: Binding(
            get: { model.pendingTotpToken != nil },
            set: { if !$0 { /* sheet dismiss handled by TOTP view */ } }
        )) {
            TOTPView()
                .environment(model)
        }
    }

    private func doLogin() async {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "服务器地址无效"
            return
        }
        isLoading = true
        errorMessage = nil
        let success = await model.login(baseURL: url, username: username, password: password)
        isLoading = false
        if !success && model.pendingTotpToken == nil {
            errorMessage = "登录失败，请检查用户名、密码或服务器地址。"
        }
    }
}

// MARK: - TOTP Sheet

private struct TOTPView: View {
    @Environment(IOSAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("两步验证") {
                    TextField("6 位验证码", text: $code)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .onChange(of: code) { _, newVal in
                            // auto-submit when 6 digits entered
                            if newVal.count == 6 {
                                Task { await doSubmit() }
                            }
                        }
                }
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.system(size: 14))
                    }
                }
                Section {
                    Button(action: { Task { await doSubmit() } }) {
                        if isLoading {
                            HStack {
                                ProgressView()
                                Text("验证中...")
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("验证")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isLoading || code.count != 6)
                }
            }
            .navigationTitle("两步验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.cancelTOTP()
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func doSubmit() async {
        isLoading = true
        errorMessage = nil
        let success = await model.submitTOTP(code: code)
        isLoading = false
        if success {
            dismiss()
        } else {
            errorMessage = "验证码错误，请重试。"
            code = ""
        }
    }
}
