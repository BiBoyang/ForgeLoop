# STEP-013：Find/Grep/Ls 工具最小落地

## 目标
- 补齐最常用检索工具：`ls`、`find`、`grep`。
- 形成“浏览 -> 定位 -> 搜索”基础闭环，支撑后续复杂任务。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`
  - `Sources/ForgeLoopAgent/Tooling/ListTool.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/FindTool.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/GrepTool.swift`（新增）
  - `Tests/ForgeLoopAgentTests/BuiltinSearchToolsTests.swift`（新增）

## 实现要求
- `ls`：
  - 输入：`path`（可选，默认 `.`）；
  - 输出：按名称排序列表（文件/目录标识可选）。
- `find`：
  - 输入：`path`、`namePattern`（最小支持 `*`）；
  - 输出：匹配路径列表（相对 cwd）。
- `grep`：
  - 输入：`path`、`pattern`；
  - 输出：`path:line:content`（最多返回前 N 条，建议 200）。
- 安全与限制：
  - 必须受 cwd 约束；
  - 目录遍历最大深度可配置（默认 6）；
  - 输出超限时截断并提示。

## 验证方式
- 命令：
  - `swift test --filter BuiltinSearchTools`
  - `swift test --filter AgentLoopToolExecution`
  - `swift test`
- 预期结果：
  - 三个工具均可执行；
  - 越界路径被拒绝；
  - 大输出可控截断。

## 风险与回滚
- 风险：
  - 递归扫描在大目录下耗时过长。
- 回滚点：
  - 增加扫描数量上限（文件数/结果数）并提前终止。
