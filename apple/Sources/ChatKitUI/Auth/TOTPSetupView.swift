import ChatKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - QR Code generation helper

/// Renders an `otpauth://` URI as an `NSImage` using Core Image's built-in
/// QR code generator. Returns nil if the URI cannot be encoded.
func qrCodeImage(from string: String, size: CGFloat = 200) -> NSImage? {
    guard let data = string.data(using: .utf8) else { return nil }

    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")   // ~15% error correction

    guard let output = filter.outputImage else { return nil }

    // Scale up from the native ~21×21 pt QR tile to the requested size.
    let scaleX = size / output.extent.width
    let scaleY = size / output.extent.height
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    let rep = NSCIImageRep(ciImage: scaled)
    let nsImage = NSImage(size: rep.size)
    nsImage.addRepresentation(rep)
    return nsImage
}

// MARK: - TOTPSetupView

/// Shown when a user logs in for the first time (totpEnabled == false).
/// Lets them scan a QR code, see their recovery code, then verify a 6-digit
/// code to activate two-factor authentication.
public struct TOTPSetupView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var code: String = ""
    @FocusState private var codeFocused: Bool

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 32)

                VStack(spacing: 28) {
                    // Title + subtitle
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(AppColors.sendButton)
                        Text("启用双因素验证")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppColors.primaryText)
                        Text("用 Google Authenticator / 1Password / Bitwarden 等扫描二维码")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }

                    if let artifacts = vm.totpSetupArtifacts {
                        // QR code
                        qrSection(artifacts: artifacts)

                        // Recovery code callout
                        recoverySection(recovery: artifacts.recovery)

                        // Code entry + verify button
                        verifySection
                    } else {
                        // Loading / error state
                        if let err = vm.loginError {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.orange)
                                Text(err)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                Button("重试") { Task { await vm.beginTotpSetup() } }
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppColors.sendButton)
                            }
                        } else {
                            ProgressView("正在生成二维码...")
                                .controlSize(.regular)
                        }
                    }

                    // Skip link
                    Button("稍后设置") { vm.skipTotpSetup() }
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.actionText)
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task { await vm.beginTotpSetup() }
        }
    }

    // MARK: - QR section

    @ViewBuilder
    private func qrSection(artifacts: (uri: String, secret: String, recovery: String)) -> some View {
        VStack(spacing: 12) {
            if let img = qrCodeImage(from: artifacts.uri, size: 200) {
                Image(nsImage: img)
                    .interpolation(.none)   // keep pixels crisp
                    .resizable()
                    .frame(width: 200, height: 200)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            } else {
                // Fallback: show just the URI as selectable text
                Text(artifacts.uri)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppColors.secondaryText)
                    .textSelection(.enabled)
                    .frame(width: 200)
                    .multilineTextAlignment(.center)
            }

            // Secret for manual entry
            VStack(spacing: 4) {
                Text("手动输入密钥")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.tertiaryText)
                Text(artifacts.secret)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(AppColors.primaryText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppColors.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Recovery code callout

    @ViewBuilder
    private func recoverySection(recovery: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("保存这个恢复码,丢失手机时可用:", systemImage: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#b05000"))
            Text(recovery)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color(hex: "#7a3a00"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .background(Color(hex: "#fff3e0"), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "#ffcc80"), lineWidth: 1)
        )
        .frame(maxWidth: 320)
    }

    // MARK: - Verify section

    private var verifySection: some View {
        VStack(spacing: 12) {
            Text("输入验证器显示的 6 位验证码")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.secondaryText)

            TextField("000000", text: $code)
                .font(.system(size: 26, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($codeFocused)
                .onChange(of: code) { _, new in
                    let filtered = new.filter(\.isNumber)
                    if filtered != new || new.count > 6 {
                        code = String(filtered.prefix(6))
                    }
                }
                .onSubmit { Task { await vm.verifyTotpSetup(code: code) } }
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
                    .multilineTextAlignment(.center)
            }

            Button(action: { Task { await vm.verifyTotpSetup(code: code) } }) {
                if vm.isLoggingIn {
                    ProgressView().controlSize(.small).frame(width: 120)
                } else {
                    Text("验证并启用").frame(width: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.sendButton)
            .disabled(vm.isLoggingIn || code.count != 6)
        }
        .onAppear { codeFocused = true }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    TOTPSetupView()
        .environment({
            let vm = AppViewModel(
                apiClient: StubAPIClient(),
                socket: StubChatSocket(),
                storage: StubStorage(),
                keychain: StubKeychain(),
                serverProfileStore: StubServerProfileStore()
            )
            vm.authState = .totpSetupRequired(user: User(id: 42, username: "stub-user"))
            return vm
        }())
        .environment(AppSettings())
        .frame(width: 480, height: 600)
}
#endif
