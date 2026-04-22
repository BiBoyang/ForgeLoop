# STEP-009：Bash 工具最小可用（前台执行）

## 目标
- 提供前台 `bash` 工具，支持超时与取消对齐当前 abort 语义。
- 作为后续后台任务系统前的最小可用命令执行能力。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/Tooling/BashTool.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/ProcessRunner.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`（注册 `bash`）
  - `Tests/ForgeLoopAgentTests/BashToolTests.swift`（新增）

## 实现要求
- 输入参数（最小）：
  - `command`（必填字符串）
  - `timeoutMs`（可选，默认 15_000）
- 执行规则：
  - 在 agent `cwd` 执行；
  - 同步等待进程结束（前台）；
  - 捕获 stdout/stderr，合并为返回文本；
  - 超时后 kill 进程并返回 `isError=true`。
- 取消语义：
  - 命中 `CancellationHandle` 时终止子进程；
  - 返回 aborted 文案，不抛未处理异常。
- 安全限制（本 step 最小）：
  - 仅支持单条命令字符串，不做 shell 多段白名单；
  - 不做后台执行，不做持久会话。

## 验证方式
- 命令：
  - `swift test --filter BashTool`
  - `swift test --filter AgentAbort`
  - `swift test --filter Agent`
- 预期结果：
  - 正常命令返回输出；
  - 超时命令返回错误且进程被回收；
  - abort 时能终止并返回 aborted 语义。

## 风险与回滚
- 风险：
  - 进程回收不彻底导致僵尸进程；
  - stderr 体积过大影响内存。
- 回滚点：
  - 先限制输出最大字节（如 64KB）并截断。
