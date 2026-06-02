import ChatKit
import Foundation

// MARK: - StubAPIClient
// TODO: swap to real APIClient on integration

public final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
    private var baseURL: URL = URL(string: "http://localhost:3000")!
    private var token: String?

    public init() {}

    public func setBaseURL(_ url: URL) async {
        baseURL = url
    }

    public func setToken(_ token: String?) async {
        self.token = token
    }

    // MARK: Auth

    public func authStatus() async throws -> Bool { false }

    public func devAuthBypassed() async -> Bool { false }

    public func login(username: String, password: String) async throws -> LoginResponse {
        // Simulate TOTP required for user "admin", otherwise direct login
        if username.lowercased() == "admin" {
            return LoginResponse(requiresTotp: true, totpToken: "stub-totp-token")
        }
        return LoginResponse(
            token: "stub-token-\(username)",
            user: User(id: 42, username: username, totpEnabled: false)
        )
    }

    public func loginWithTOTP(totpToken: String, code: String) async throws -> LoginResponse {
        // Accept any 6-digit code
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw ChatKitError.totpFailed(message: "需要 6 位数字验证码")
        }
        return LoginResponse(
            token: "stub-final-token",
            user: User(id: 1, username: "admin", totpEnabled: true)
        )
    }

    public func currentUser() async throws -> User {
        User(id: 42, username: "stub-user")
    }

    public func logout() async throws {}

    public func setupTOTP() async throws -> (secret: String, provisioningUri: String, recoveryCode: String) {
        let secret = "JBSWY3DPEHPK3PXP"   // well-known test secret (base32)
        let uri = "otpauth://totp/ClaudeChat%3Astub-user?secret=\(secret)&issuer=ClaudeChat"
        let recovery = "stub-recovery-code-abc"
        return (secret: secret, provisioningUri: uri, recoveryCode: recovery)
    }

    public func verifyTOTPSetup(secret: String, code: String, recoveryCode: String) async throws {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw ChatKitError.totpFailed(message: "需要 6 位数字验证码")
        }
        // Stub: accept any well-formed 6-digit code
    }

    public func fetchCommands(projectPath: String?) async throws -> [CommandInfo] {
        [
            CommandInfo(name: "/help",   description: "Show help documentation", namespace: "builtin"),
            CommandInfo(name: "/clear",  description: "Clear the conversation",  namespace: "builtin"),
            CommandInfo(name: "/cost",   description: "Show token cost",          namespace: "builtin"),
            CommandInfo(name: "/model",  description: "Switch model",             namespace: "builtin"),
        ]
    }

    // MARK: Projects + Sessions

    public func fetchProjects() async throws -> [ProjectInfo] {
        [
            ProjectInfo(id: "proj-1", displayName: "claudecodeui-local", path: "/Users/stub/claudecodeui-local"),
            ProjectInfo(id: "proj-2", displayName: "my-app",             path: "/Users/stub/my-app"),
        ]
    }

    public func fetchSessions() async throws -> [SessionInfo] {
        let now = Date()
        return [
            SessionInfo(id: "sess-1", projectPath: "/Users/stub/claudecodeui-local",
                        projectDisplayName: "claudecodeui-local",
                        title: "写 macOS 客户端设计",
                        lastActivityAt: now,
                        isActive: true, messageCount: 12),
            SessionInfo(id: "sess-2", projectPath: "/Users/stub/my-app",
                        projectDisplayName: "my-app",
                        title: "回测策略胜率",
                        lastActivityAt: now.addingTimeInterval(-3600),
                        isActive: false, messageCount: 8),
            SessionInfo(id: "sess-3", projectPath: "/Users/stub/claudecodeui-local",
                        projectDisplayName: "claudecodeui-local",
                        title: "修 TOTP 登录 bug",
                        lastActivityAt: now.addingTimeInterval(-7200),
                        isActive: false, messageCount: 5),
            SessionInfo(id: "sess-4", projectPath: "/Users/stub/my-app",
                        projectDisplayName: "my-app",
                        title: "周报技术总结",
                        lastActivityAt: now.addingTimeInterval(-172800),
                        isActive: false, messageCount: 3),
        ]
    }

    public func fetchMessages(sessionId: String) async throws -> [ChatMessage] {
        let now = Date()
        switch sessionId {
        case "sess-1":
            return [
                ChatMessage(id: "msg-1", sessionId: sessionId, role: .user,
                            content: "那 SwiftData schema 怎么写?",
                            createdAt: now.addingTimeInterval(-600)),
                ChatMessage(id: "msg-2", sessionId: sessionId, role: .assistant,
                            content: "需要三张表 SessionRecord、MessageRecord、ServerProfile。SessionRecord 主键是后端 sessionId, 保留 isHidden 软删字段, 关联 messages 用 cascade delete rule。",
                            createdAt: now.addingTimeInterval(-580)),
                ChatMessage(id: "msg-3", sessionId: sessionId, role: .user,
                            content: "帮我写完整的代码",
                            createdAt: now.addingTimeInterval(-300)),
                ChatMessage(id: "msg-4", sessionId: sessionId, role: .tool,
                            content: "",
                            toolUse: ToolInvocation(name: "Read", input: "{\"path\":\"Sources/ChatKit/DTOs.swift\"}", output: nil, approvalState: .approved, requiresApproval: false),
                            createdAt: now.addingTimeInterval(-295)),
                ChatMessage(id: "msg-5", sessionId: sessionId, role: .assistant,
                            content: "好的，以下是完整的 SwiftData 模型实现:\n\n```swift\nimport Foundation\nimport SwiftData\n\n@Model final class SessionRecord {\n    @Attribute(.unique) var id: String\n    var projectPath: String\n    var title: String\n    var lastActivityAt: Date\n    var isHidden: Bool = false\n    var unreadCount: Int = 0\n}\n```\n\n这个实现包含了所有必要的字段和关系。",
                            createdAt: now.addingTimeInterval(-290)),
            ]
        case "sess-2":
            return [
                ChatMessage(id: "msg-b1", sessionId: sessionId, role: .user,
                            content: "帮我分析这个回测策略的胜率",
                            createdAt: now.addingTimeInterval(-3600)),
                ChatMessage(id: "msg-b2", sessionId: sessionId, role: .assistant,
                            content: "已生成 backtest_v2.py，分析结果如下：胜率 63.2%，最大回撤 12.4%。",
                            createdAt: now.addingTimeInterval(-3550)),
            ]
        default:
            return []
        }
    }

    public func fetchMessagesPage(
        sessionId: String,
        limit: Int?,
        offset: Int
    ) async throws -> (messages: [ChatMessage], total: Int, hasMore: Bool) {
        let all = try await fetchMessages(sessionId: sessionId)
        let total = all.count
        let limit = limit ?? 200
        let start = max(0, total - offset - limit)
        let end = max(0, total - offset)
        let slice = Array(all[start..<end])
        let hasMore = start > 0
        return (messages: slice, total: total, hasMore: hasMore)
    }
}
