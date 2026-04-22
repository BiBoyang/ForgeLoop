# STEP-018：Tool 参数校验与错误模型统一

## 目标
- 统一各工具参数校验与错误输出格式，减少模型重试成本。
- 建立一套可复用的工具错误模型（缺参/越界/执行失败/超限）。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/Tooling/ToolExecutor.swift`
  - `Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`
  - `Sources/ForgeLoopAgent/Tooling/EditTool.swift`
  - `Sources/ForgeLoopAgent/Tooling/FindTool.swift`
  - `Sources/ForgeLoopAgent/Tooling/GrepTool.swift`
  - `Sources/ForgeLoopAgent/Tooling/BashTool.swift`
  - `Tests/ForgeLoopAgentTests/*ToolTests.swift`

## 实现要求
- 定义统一错误结构（建议：`code`、`message`、`hint`）。
- 参数缺失时输出稳定错误码（如 `missing_argument`）。
- 路径越界与权限错误使用可区分错误码。
- 输出上限触发时使用统一提示文本，便于模型二次决策。

## 验证方式
- 命令：
  - `swift test --filter Tool`
  - `swift test --filter AgentLoopToolExecution`
  - `swift test`
- 预期结果：
  - 错误文案结构稳定；
  - 现有测试通过并补齐异常路径测试。

## 风险与回滚
- 风险：
  - 文案升级导致旧断言批量失效。
- 回滚点：
  - 先保持原文案兼容字段，再逐步迁移断言。
