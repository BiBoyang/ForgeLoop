import Foundation
import ForgeLoopAI
import ForgeLoopDiagnostics
import ForgeLoopSandbox

/// 沙箱 profile 构造策略（对齐 Codex，在调用方而非纯函数层完成校验——Review 移交项）。
///
/// 默认 `workspaceWrite(writableRoots: [cwd])` + `network: .disabled`。
/// 每个 writable root 必须 **存在、为目录、非 symlink、不含控制字符**（防 sbpl 注入）；
/// 不满足的 root 被拒绝并随返回值上报记录，全部拒绝时降级 `readOnly`。
public enum SandboxProfileFactory {
    /// 被拒绝的 writable root 及原因（供调用方记录日志）。
    public struct RejectedRoot: Sendable, Equatable {
        public let path: String
        public let reason: String
    }

    /// 校验 writable roots，返回 (有效列表, 拒绝列表)。
    public static func validateWritableRoots(_ roots: [URL]) -> (valid: [URL], rejected: [RejectedRoot]) {
        var valid: [URL] = []
        var rejected: [RejectedRoot] = []
        for root in roots {
            let path = root.path
            if path.rangeOfCharacter(from: .controlCharacters) != nil {
                rejected.append(RejectedRoot(path: path, reason: "path contains control characters"))
                continue
            }
            var st = stat()
            guard lstat(path, &st) == 0 else {
                rejected.append(RejectedRoot(path: path, reason: "path does not exist"))
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                rejected.append(RejectedRoot(path: path, reason: "path is a symlink"))
                continue
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                rejected.append(RejectedRoot(path: path, reason: "path is not a directory"))
                continue
            }
            valid.append(root)
        }
        return (valid, rejected)
    }

    /// 构造默认 profile：workspaceWrite(cwd) + 断网；cwd 校验失败时降级 readOnly。
    public static func makeDefault(cwd: String) -> (profile: PermissionProfile, rejected: [RejectedRoot]) {
        let (valid, rejected) = validateWritableRoots([URL(fileURLWithPath: cwd)])
        if valid.isEmpty {
            return (PermissionProfile(fileSystem: .readOnly, network: .disabled), rejected)
        }
        return (PermissionProfile(fileSystem: .workspaceWrite(writableRoots: valid), network: .disabled), rejected)
    }
}

public struct CodingAgentConfig: Sendable {
    public var model: Model
    public var cwd: String
    public var systemPrompt: String?
    public var toolExecutionMode: ToolExecutionMode
    public var subagents: [SubagentDefinition]
    public var streamFn: StreamFn?
    /// 沙箱策略覆盖口子。nil = 默认 `workspaceWrite(cwd)` + 断网；
    /// 传 `fullAccess + network enabled` 即完全放行（配置/UI 接线不在本期范围）。
    public var sandboxProfile: PermissionProfile?
    /// 沙箱拒绝后的升级审批策略，默认 onFailure。
    public var approvalPolicy: ApprovalPolicy
    /// 升级审批回调（CLI 注入交互 UI）；nil = 不审批，等价 never（AppKit 默认走这里）。
    public var escalationHandler: SandboxEscalationHandler?

    public init(
        model: Model,
        cwd: String,
        systemPrompt: String? = nil,
        toolExecutionMode: ToolExecutionMode = .sequential,
        subagents: [SubagentDefinition] = [],
        streamFn: StreamFn? = nil,
        sandboxProfile: PermissionProfile? = nil,
        approvalPolicy: ApprovalPolicy = .default,
        escalationHandler: SandboxEscalationHandler? = nil
    ) {
        self.model = model
        self.cwd = cwd
        self.systemPrompt = systemPrompt
        self.toolExecutionMode = toolExecutionMode
        self.subagents = subagents
        self.streamFn = streamFn
        self.sandboxProfile = sandboxProfile
        self.approvalPolicy = approvalPolicy
        self.escalationHandler = escalationHandler
    }
}

public func makeCodingAgent(
    _ config: CodingAgentConfig,
    diagnostics: Diagnostics = Diagnostics()
) async -> Agent {
    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(cwd: config.cwd)
    let toolExecutor = ToolExecutor(diagnostics: diagnostics)
    toolExecutor.register(ReadTool())
    toolExecutor.register(WriteTool())
    toolExecutor.register(EditTool())
    toolExecutor.register(ListTool())
    toolExecutor.register(FindTool())
    toolExecutor.register(GrepTool())

    // 沙箱 profile：默认 workspaceWrite(cwd) + 断网；被拒绝的 writable root 记录日志
    let sandboxProfile: PermissionProfile
    if let override = config.sandboxProfile {
        sandboxProfile = override
    } else {
        let made = SandboxProfileFactory.makeDefault(cwd: config.cwd)
        sandboxProfile = made.profile
        for rejected in made.rejected {
            await diagnostics.log.log(
                level: .warn,
                message: "sandbox writable root rejected; degraded profile may apply",
                attributes: [
                    "path": .string(rejected.path),
                    "reason": .string(rejected.reason),
                ]
            )
        }
    }

    let bgManager = BackgroundTaskManager(profile: sandboxProfile)
    toolExecutor.register(BashTool(
        manager: bgManager,
        profile: sandboxProfile,
        policy: config.approvalPolicy,
        escalationHandler: config.escalationHandler
    ))
    toolExecutor.register(BgTool(manager: bgManager))
    toolExecutor.register(BgStatusTool(manager: bgManager))

    let agent = Agent(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model
        ),
        streamFn: config.streamFn,
        toolExecutor: toolExecutor,
        cwd: config.cwd,
        diagnostics: diagnostics
    )
    agent.toolExecutionMode = config.toolExecutionMode
    agent.backgroundTaskManager = bgManager
    agent.setupBackgroundNotifications(manager: bgManager)

    if !config.subagents.isEmpty {
        let agentTool = createAgentTool(
            subagents: config.subagents,
            config: config,
            parentSessionId: "",
            diagnostics: diagnostics
        )
        toolExecutor.register(agentTool)
    }

    return agent
}
