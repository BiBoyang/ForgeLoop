# REVIEW-sandbox-approval-2026-10-12

## 结论
**Approved**

## 证据制核对
| 项 | 结果 | 证据 |
|---|---|---|
| 验收标准零漂移 | Done | TASK/PROMPT 哈希与派发前一致（TASK 含 Owner 批准扩 scope 注记，哈希以派发时记录为准） |
| status 过程记录 | Done | 3 行 |
| Sandbox 测试 | Done | Reviewer 独立复跑 → 29/29（含新增 ApprovalAndDenialTests 7 用例） |
| Agent 测试 | Done | Reviewer 独立复跑 → 229/229（含新增 SandboxEscalationTests 7 用例） |
| 全套回归 | Done | Reviewer 独立复跑 `swift test` → 无失败行，exit 0 |
| 范围纪律 | Done | 全部在任务书清单内（含 Owner 批准的 SubagentRunner/SubagentTool）；REVIEW-LOG 等留给 docs 任务 |
| DoD 逐项 | Done | 启发式锚点收紧/重跑一次不递归/cancellation 复查/ListPicker 阻塞等待默认落"拒绝"/非 TTY 不注入 handler/subagent 覆盖 |

## 代码评审要点（diff 全读）
- 升级链路不递归：批准后直调 `ProcessRunner(profile: nil)`，结构上保证仅一次；等待后与重跑后均复查 cancellation。
- `SandboxApprovalBridge` 的 `@unchecked Sendable` 安全不变量有注释且成立（弱引用 + MainActor 一次性写入 + request 立即跳 MainActor）；init 顺序论证正确（handler 不可能早于 bridge 回接触发）。
- 审批默认选中"拒绝"、Esc=拒绝、非 TTY 不注入——fail-closed 方向全部正确。
- 启发式锚点收紧正确：curl exit 6 不触发升级，注释说明 v1 边界。

## Findings
- [Minor] SubagentRunner 实际是 `childConfig.sandboxProfile override ?? SandboxProfileFactory.makeDefault(childCwd)`，**并非字面意义的"父 profile 透传"**。方向 fail-closed（父 fullAccess 不会泄漏给子），且更贴合 Codex"对父的批准不构成对子的一般许可"的语义；但与 DoD 5 措辞有偏差，docs 任务需在架构文档/移植笔记中注明该语义。
- [Minor]（Executor 披露）代码路径 abort 不会 resume 挂起的审批 continuation（用户 Esc 已覆盖）。v1 接受为已知限制，进 docs。
- [Minor] TUI 手工冒烟未做（TTY 依赖，DoD 未要求自动化）——转入 Owner 验收清单。

## 测试意见
启发式正负例覆盖到位（spike 真实样本 + 3 类负例）；流程三分支 + handler 缺失 + 非拒绝不触发 + subagent 覆盖，Agent 层 fake handler 设计合理。

## 残余风险
审批挂起期间 agent 若被代码路径 abort，bash 调用悬置直至用户操作——已记录，影响限于 UI 层一次等待。

## 变更摘要
ForgeLoopSandbox +2 文件（policy/启发式）；BashTool 升级链路；SubagentRunner 沙箱化（裸奔通道关闭）；CLI 阻塞式审批 UI；+14 测试用例。全套回归无失败。
