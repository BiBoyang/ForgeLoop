---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-tool-schema-wiring.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：让模型真正收到工具定义（TASK-tool-schema-wiring）

## 目标
Tool 协议扩展出 `definition`（name + description + 参数 JSON Schema），AgentLoop 经 `StreamOptions.tools` 传给 provider。
成功标准：ChatCompletions/Anthropic/Responses 三个 provider 的请求体都含合法 tools 数组；`swift test --filter Agent` 与 `--filter AI` 全绿。

## 背景（必读，都是已核实的一手事实）
- `Sources/ForgeLoopAgent/AgentLoop.swift` 构造 `StreamOptions` 不传 tools（第 63 行附近），全仓库无任何调用点传——模型从未见过工具定义
- `Sources/ForgeLoopAgent/Tooling/ToolExecutor.swift:51` 的 `Tool` 协议只有 `name` + `execute`
- `StreamOptions.tools: [ToolDefinition]?` 已存在（`Sources/ForgeLoopAI/Context.swift:65`），`ToolDefinition(name:description:parametersJSON:)` 已有
- provider 侧：`OpenAIChatCompletionsProvider.swift:475` 与 `AnthropicProvider.swift:481` 已会序列化 `options.tools`；**`OpenAIResponsesProvider` 需检查，没有则按 Responses API 规范补**
- 参数 schema 素材：各工具已有 `ToolArgsSchema`（`Tooling/ToolArgsValidation.swift`），可加一个到 JSON Schema 的映射，减少手写
- FauxProvider 伪造 tool call、不消费定义，是全项目没发现此缺口的原因——不要以 faux 行为推断真实链路

## 涉及文件（绝对路径）
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/`（ToolExecutor.swift + 全部内建工具 + SubagentTool.swift）
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/AgentLoop.swift`
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAI/OpenAIResponsesProvider.swift`（仅当确认缺 tools 序列化时）
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopAgentTests/` 与 `Tests/ForgeLoopAITests/`
- 不动 ForgeLoopCli/ForgeLoopApp；文档不动（另行收口）

## 验收标准（DoD）
1. Tool 协议增加 `var definition: ToolDefinition { get }`；全部内建工具与 SubagentTool 实现；description 简洁、面向模型、含边界说明
2. ToolExecutor 提供 `toolDefinitions` 只读快照；AgentLoop 每轮 stream 携带当前全集
3. 三 provider 请求体单测断言 tools 结构符合各自规范（ChatCompletions: `tools[].function.{name,description,parameters}`；Anthropic: `tools[].{name,description,input_schema}`；Responses 按其规范）
4. 工具参数的 JSON Schema 与既有 ToolArgsSchema 校验语义一致（required/类型一致，不自相矛盾）
5. `swift test --filter Agent`、`swift test --filter AI` 全绿；`swift build` 无新警告
6. 遵循 AGENTS.md §4/§5：事件闭环不破；纯数据生成用 Sendable struct；`@unchecked Sendable` 需写明不变量

## 上游任务产出
无（独立任务）

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-tool-schema-wiring.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
