# STEP-007：AgentLoop 真实工具执行闭环（含 tool_result 注入）

## 目标
- 将当前 `toolExecutionStart/End` 占位事件升级为“真实执行闭环”。
- 保证关键顺序：assistant(tool_call) 先入上下文，再执行工具，再注入 `tool_result`。
- 支持继续回合，让模型读取 `tool_result` 后产出最终回答。

## 实现范围
- 涉及模块：`ForgeLoopAI`、`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAI/Messages.swift`（补 `tool` 角色消息）
  - `Sources/ForgeLoopAgent/AgentTypes.swift`（补工具执行配置）
  - `Sources/ForgeLoopAgent/AgentLoop.swift`（从占位改为真实执行）
  - `Sources/ForgeLoopAgent/Agent.swift`（透传工具执行器）
  - `Sources/ForgeLoopAgent/Tooling/*.swift`（新增：协议与执行入口）
  - `Tests/ForgeLoopAgentTests/AgentLoopToolExecutionTests.swift`（新增）

## 实现要求
- 新增最小工具抽象：
  - `ToolExecutor`（按 `name + arguments` 执行，返回文本结果或错误）。
  - 返回结构至少包含：`isError`、`outputText`。
- 回合逻辑：
  1) 收到 assistant 最终消息；
  2) 将 assistant 消息 append 到 context；
  3) 逐个执行 `toolCall`（本 step 先串行）；
  4) 每个调用都发 `toolExecutionStart/End`；
  5) 将工具结果注入为 `tool_result` 消息并 append 到 context；
  6) 若存在任一 `tool_result`，继续下一轮 provider 请求（直到无 tool_call）。
- 错误语义：
  - 工具执行失败不应中断整次 run；
  - 失败结果作为 `tool_result(isError=true)` 注入上下文，让模型自我纠正。
- 循环保护：
  - 增加最大 tool turn 限制（建议 8），超限后以 `.error` 收敛并结束。

## 验证方式
- 命令：
  - `swift test --filter AgentLoopToolExecution`
  - `swift test --filter AgentLoopToolEvents`
  - `swift test --filter Agent`
- 预期结果：
  - 能看到真实工具执行事件；
  - 上下文顺序包含 `assistant(tool_call)` 后接 `tool_result`；
  - 工具失败可继续回合并最终收敛。

## 风险与回滚
- 风险：
  - tool_result 角色建模改动影响 provider 输入映射；
  - 回合循环可能出现无限递归。
- 回滚点：
  - 保留占位事件逻辑分支（feature flag 或小范围 revert）。
