# TASK-sandbox-approval：拒绝检测与 CLI 审批升级

- 状态：done
- 依赖：TASK-sandbox-wire
- 下游：TASK-sandbox-docs

## 目标
对齐 Codex `core/src/exec.rs` 的两段式：沙箱执行失败被启发式判定为"沙箱拒绝"时，按 ApprovalPolicy 向用户请求升级，批准后以非沙箱方式重跑一次；拒绝则按失败回灌模型。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopSandbox/`（或 ForgeLoopAgent，以分层合理为准）：`SandboxDenialHeuristic`——输入退出码+stderr，输出是否疑似沙箱拒绝；特征数据来自 TASK-sandbox-spike 报告（EPERM/"operation not permitted" 等）
- 新增 `ApprovalPolicy.swift`：`never / onFailure` 两档（默认 onFailure），Codable
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/BashTool.swift` 与 AgentLoop 相关文件：升级请求经现有 AgentHooks/事件链路上浮，不在工具内部直接交互
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/SubagentRunner.swift`（**Owner 批准的扩 scope 项，2026-10-12**：将主 agent 的 sandbox profile 透传进 subagent 的 BackgroundTaskManager/BashTool，堵住裸奔通道；subagent 不接审批 handler，拒绝即失败）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/`（CodingTUISession 相关）：审批提示 UI——展示命令、原因，提供 `允许一次 / 拒绝`；允许后非沙箱重跑一次（仅一次，不再循环升级）
- 测试：启发式单测（用 spike 报告的真实样本）；升级流程测试用 mock runner 覆盖"拒绝→批准→重跑成功""拒绝→拒绝→错误回灌""policy=never 直接失败"三分支

## DoD
- 三分支流程均有测试覆盖；审批交互不复用 footer notice，必须阻塞等待用户输入（对齐 /model picker 的交互形态）
- 重跑仅一次；同一命令反复失败不会形成升级循环
- `swift test --filter Agent` 与 `swift test --filter ForgeLoopSandbox` 全绿
- AppKit 侧本期不接（后续任务）

## 验证命令
- `swift test --filter Agent`；TUI 手工冒烟：agent 触发越界写 → 出现审批提示 → 允许后成功
