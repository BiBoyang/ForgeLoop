# REVIEW-tool-schema-wiring-2026-10-12

## 结论
**Approved**

## 证据制核对
| 项 | 结果 | 证据 |
|---|---|---|
| 验收标准零漂移 | Done | TASK/PROMPT 哈希与派发时一致 |
| status 过程记录 | Done | 4 行，含"Responses provider 缺失 tools 序列化"的确认记录 |
| Agent 测试 | Done | Reviewer 独立复跑 → 235/235（+6 新用例） |
| AI 测试 | Done | Reviewer 独立复跑 → 63/63（Responses tools 断言） |
| 全套回归 | Done | Reviewer 独立复跑 `swift test` → 无失败，exit 0 |
| 范围纪律 | Done | git status 本任务文件均在清单内；README/docs/plans-sandbox-docs 脏文件确认为上一批未提交的 docs 任务产物，非本任务混入 |

## 代码评审要点（diff 全读）
- `ToolExecutor.toolDefinitions` 按 name 排序——请求体确定性（利于 provider 端缓存命中），细节加分。
- `ToolArgsSchema.jsonSchema()`：`additionalProperties: false` 与校验器的未知字段拒绝语义对齐；`numberOrString` → `anyOf` 的处理正确。
- Responses provider 用 JSONSerialization 往返注入扁平 tools——绕开 Encodable 对任意 JSON parameters 的限制，结构符合 Responses API 规范。
- BashTool 的 description 含沙箱提示（"Commands may run sandboxed and can be denied"）——给模型的上下文完整。

## Findings
- [Minor] BashTool 的 `definition` 属性插入位置在存储属性之间（`defaultTimeoutMs` 之前），纯属排版，不阻塞。
- [提示] 工具定义上线后 token 消耗会上升（9+ 工具 schema 每轮随请求发送）；后续可考虑对齐 Codex 的工具集裁剪/缓存策略，非本期范围。

## 测试意见
schema↔validator 一致性（required/类型）、未知字段拒绝、SubagentTool 动态 enum、快照排序、AgentLoop 透传均有用例，覆盖了这类改动最容易碎的点。

## 残余风险
真实模型的工具调用行为尚未验证——转 Owner 真机验收（一条指令同时覆盖：工具调用 + 沙箱拒绝 + 审批 picker）。

## 变更摘要
Tool 协议 +definition；9 内建工具 + SubagentTool 定义落地；AgentLoop 接线；Responses provider 补 tools；+6 Agent 用例、AI 用例增强。全套回归无失败。
