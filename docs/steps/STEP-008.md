# STEP-008：Read/Write 工具落地与基础安全约束

## 目标
- 提供最小可用 `read`、`write` 工具。
- 建立 cwd 范围内的路径安全约束，防止越界访问。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/PathGuard.swift`（新增）
  - `Sources/ForgeLoopAgent/CodingAgentBuilder.swift`（注册默认工具）
  - `Tests/ForgeLoopAgentTests/BuiltinReadWriteToolTests.swift`（新增）

## 实现要求
- `read` 工具：
  - 输入：`path`；
  - 输出：文件文本内容；
  - 文件不存在时返回结构化错误（`isError=true`）。
- `write` 工具：
  - 输入：`path`、`content`；
  - 默认覆盖写；
  - 返回写入确认（字节数/文件路径）。
- 安全约束（必须）：
  - 所有路径先 `standardizedFileURL` 再校验；
  - 目标必须在 `cwd` 根目录下；
  - 拒绝目录穿越（`..`）越界；
  - 对目录执行 `write` 返回明确错误。
- 错误语义：
  - 工具内部错误转换为用户可读文本，不抛致命异常。

## 验证方式
- 命令：
  - `swift test --filter BuiltinReadWriteTool`
  - `swift test --filter AgentLoopToolExecution`
  - `swift test --filter Agent`
- 预期结果：
  - 读写在 cwd 内可用；
  - 越界路径被拒绝；
  - 错误能回流到 `tool_result`。

## 风险与回滚
- 风险：
  - 路径规范化在符号链接场景可能误判。
- 回滚点：
  - 保留严格前缀检查版本（无符号链接展开）。
