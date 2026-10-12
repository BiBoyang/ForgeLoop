# TASK-tool-schema-wiring：让模型真正收到工具定义

- 状态：done
- 依赖：无（沙箱项目已收官；这是验收中发现的独立缺口）
- 上游证据：AgentLoop.swift 构造 StreamOptions 从不传 tools；Tool 协议（ToolExecutor.swift:51）只有 name+execute，无 schema

## 目标
把工具定义（name + description + JSON Schema 参数）从 Tool 一路接到 provider 请求体，让真实模型能发起工具调用。这是 coding agent 形态的基础——没有它 agent 只能聊天。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/ToolExecutor.swift`（Tool 协议增加 `definition: ToolDefinition`；ToolExecutor 增加 `toolDefinitions` 只读快照）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/` 下全部内建工具（Read/Write/Edit/Find/Grep/List/Bash/Bg/BgStatus 等）：补 description 与参数 JSON Schema（优先从既有 `ToolArgsSchema` 生成映射，映射不了的手写）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/SubagentTool.swift`（同样补 definition）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/AgentLoop.swift`（StreamOptions 传 tools + 合理 toolChoice）
- 检查 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAI/OpenAIResponsesProvider.swift` 是否序列化 options.tools（ChatCompletions/Anthropic 已有；Responses 若无则补，格式对齐该 API 规范）
- 测试：Tests/ForgeLoopAgentTests 下新增/修改

## DoD
1. 每个注册工具都有 definition：description 用一句话说清用途与边界（写给模型看的），parametersJSON 是合法 JSON Schema（object/properties/required）
2. AgentLoop 每次 stream 请求携带当前注册工具全集；工具动态增删（如 subagent 注册）能反映在下一次请求
3. 单测：ChatCompletions 与 Anthropic 请求体含 tools 数组且字段名符合各自 API 规范；Responses provider 同样覆盖；faux 路径不受影响
4. `swift test --filter Agent` 与 `swift test --filter AI` 全绿；`swift build` 无新警告
5. AGENTS.md §4/§5 不变量不破；纯数据生成用 Sendable struct

## 验证命令
- `swift test --filter Agent`；`swift test --filter AI`
- 真机验收（Owner）：TUI 里"用 bash 在 home 目录创建 ~/forgeloop-sandbox-smoke.txt"应触发 bash 工具调用 + 沙箱审批 picker

## 备注
- description/schema 质量直接影响模型工具调用意愿，措辞参考 Codex 工具描述的简洁风格
- 本任务不做：工具结果截断策略、并行 tool call 调度优化
