# STEP-021：模型管理与配置持久化（最小）

## 目标
- 将当前 `/model` 的临时切换能力升级为可持久化配置。
- 支持启动时恢复上次模型设置。

## 实现范围
- 涉及模块：`ForgeLoopCli`、`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/AuthResolver.swift`
  - `Sources/ForgeLoopCli/PromptController.swift`
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Sources/ForgeLoopCli/ModelStore.swift`（新增）
  - `Tests/ForgeLoopCliTests/ModelStoreTests.swift`（新增）

## 实现要求
- 新增 `ModelStore`（本地 JSON 文件持久化）。
- `/model <id>` 成功后写入 store。
- 启动时按优先级解析模型：
  - CLI 显式参数 > 持久化配置 > 默认模型。
- 读取失败时回退默认模型，不阻塞启动。

## 验证方式
- 命令：
  - `swift test --filter ModelStore`
  - `swift test --filter SlashCommands`
  - `swift test`
- 预期结果：
  - 模型切换跨会话生效；
  - 异常配置文件不影响主流程。

## 风险与回滚
- 风险：
  - 配置文件损坏导致解析异常。
- 回滚点：
  - 增加容错重置逻辑（坏文件改名备份）。
