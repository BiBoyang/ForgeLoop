# STEP-012：Edit 工具最小落地（补丁写入）

## 目标
- 提供 `edit` 工具，支持按“旧文本 -> 新文本”的最小替换写入。
- 延续 `read/write` 的 cwd 安全约束，避免越界修改。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`
  - `Sources/ForgeLoopAgent/Tooling/EditTool.swift`（新增）
  - `Sources/ForgeLoopAgent/CodingAgentBuilder.swift`
  - `Tests/ForgeLoopAgentTests/EditToolTests.swift`（新增）

## 实现要求
- 输入参数（最小）：
  - `path`（必填）
  - `oldText`（必填）
  - `newText`（必填）
- 执行规则：
  - 路径经 `PathGuard` 校验，必须在 `cwd` 内；
  - 文件必须存在且为普通文件；
  - 默认只替换第一个命中的 `oldText`（最小语义）；
  - 未命中时返回 `isError=true`。
- 输出：
  - 成功返回替换确认（文件路径 + 替换次数）。

## 验证方式
- 命令：
  - `swift test --filter EditTool`
  - `swift test --filter BuiltinReadWriteTool`
  - `swift test --filter Agent`
- 预期结果：
  - edit 在 cwd 内可用；
  - 越界/未命中/目录路径均返回明确错误。

## 风险与回滚
- 风险：
  - 文本替换对大文件性能不稳定。
- 回滚点：
  - 限制单次处理文件大小（例如 1MB）并返回错误提示。
