import Foundation

public enum ChatKitError: LocalizedError, Sendable {
    case notAuthenticated
    case totpRequired(userId: Int)
    case totpFailed(message: String)
    case httpStatus(code: Int, body: String)
    case decoding(underlying: String)
    case websocketDisconnected
    case websocketProtocol(message: String)
    case keychain(status: Int32)
    case storage(message: String)
    case unsupportedURL(URL)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "请先登录"
        case .totpRequired: return "需要输入 TOTP 验证码"
        case .totpFailed(let m): return "TOTP 验证失败: \(m)"
        case let .httpStatus(code, _): return "服务端返回 \(code)"
        case .decoding(let u): return "响应解析失败: \(u)"
        case .websocketDisconnected: return "WebSocket 已断开"
        case .websocketProtocol(let m): return "WebSocket 协议错误: \(m)"
        case .keychain(let s): return "Keychain 错误 (\(s))"
        case .storage(let m): return "本地存储错误: \(m)"
        case .unsupportedURL(let u): return "不支持的 URL: \(u)"
        case .other(let m): return m
        }
    }
}
