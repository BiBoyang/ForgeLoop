# STEP-003：TranscriptRenderer 覆盖更新增强

## 目标
- 让 TUI transcript 的流式渲染稳定为“覆盖更新”语义，避免重复行/残留行。
- 为后续工具结果渲染打好结构（`running...` 占位可被正确替换）。

## 实现范围
- 模块：`ForgeLoopCli`
- 文件：
  - `Sources/ForgeLoopCli/TranscriptRenderer.swift`
  - （可选）`Sources/ForgeLoopCli/CodingTUI.swift`（仅当需要接线微调）
  - `Tests/ForgeLoopCliTests/`（新增 renderer 相关测试）

## 实现要求

### 1) streaming 覆盖更新必须严格成立
- 继续使用 `streamingRange`，但要确保：
  - `messageStart(.assistant)` 时只“占位”，不追加重复内容。
  - 每个 `messageUpdate` 都替换同一区段（不是 append）。
  - `messageEnd(.assistant)` 后清空 `streamingRange`。
- 当新更新行数比上一次少时，旧尾巴不能残留。

### 2) 用户消息与 assistant 流式边界清晰
- `messageStart(.user)` 仍按稳定块写入（含空行分隔）。
- assistant streaming 期间不得重复插入额外空行。
- `messageEnd(.assistant)` 才追加最终分隔空行。

### 3) 为 tool 事件预留稳定占位替换
- 处理 `toolExecutionStart`：
  - 追加 `● tool(args)` + `⎿ running...`
  - 保存该 tool 的 header/占位位置（如 `pendingTools` map）
- 处理 `toolExecutionEnd`：
  - 用结果占位文本替换 `running...` 行
  - 当前 STEP-002 里只有 `isError`，可先输出：
    - 成功占位：`⎿ done`
    - 错误占位：`⎿ failed (placeholder)`

> 注意：本 step 不要求真实 tool output 文本渲染，只要占位替换链路正确。

### 4) 行缓冲 API 要可控
- `TranscriptBuffer.replace(range:with:)` 与 `replace(from:with:)` 的越界行为要可预期。
- 覆盖更新后，`lines.all` 不能出现“旧内容 + 新内容拼接残影”。

## 验收标准
- 连续 `messageUpdate`（长->短->长）后，最终只保留最后一版内容。
- `messageEnd(.assistant)` 后 `streamingRange == nil`（可通过行为侧验证）。
- tool start/end 后，`running...` 被替换，不会重复保留两行。
- 不影响现有 Agent 测试。

## 建议测试用例（至少 4 个）
1. `messageUpdate` 覆盖：两次更新只保留后者文本。
2. 更新行数缩短：旧尾行不残留。
3. `messageEnd` 后分隔空行只出现一次。
4. `toolExecutionStart -> End`：`running...` 被替换为 done/failed 占位。

## 验证命令
- `swift test --filter Transcript`
- `swift test --filter TUI`
- 最后回归：`swift test --filter Agent`

## 提交前注意
- 保持 `TranscriptRenderer` 为纯事件消费器，不直接读写 Agent 状态。
- 本 step 目标是“渲染一致性”，不要扩展到输入绑定逻辑。
