# TASK-submit-nonblocking：提交不阻塞事件循环

- 状态：done
- 依赖：无（审批 picker 渲染已修，此为输入侧结构性修复）
- 上游证据：trace/代码实证 —— eventLoop await handleResolvedKey → … → agent.prompt → runLifecycle await 整个 run（Agent.swift）；run 期间按键全部积压，审批 picker 无法操作

## 目标
提交 agent run 后立即返回，事件循环在 run 期间保持响应：审批 picker 可操作、Esc 可中断、后续消息可 steer/排队。

## 候选方案（Owner 已选 B）
- B：`SessionCoordinator.submit` 的非 streaming 分支 spawn 后台 Task 执行 `agent.prompt`，立即返回 `.submitted`；run 错误经既有 agent 事件流上抛（不再经 throw）。CLI/AppKit 同时受益。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/SessionCoordinator.swift`
- 必要时修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/PromptController.swift`、`CodingTUISession+Input.swift`（SubmitResult/错误处理适配）
- 测试：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopCliTests/`

## DoD
1. 非 streaming 提交立即返回（不等 run 结束）；slash 命令仍同步处理（本地、快速）
2. run 期间：键盘事件正常分发（picker 可操作）；Esc 中断 run 有效；新消息走 steer/queue 路径
3. run 启动失败（如 hook 阻止、alreadyRunning）仍有可见反馈（事件或 notice），不静默吞掉
4. `swift test --filter Cli` 与 `swift test --filter Agent` 全绿；新增"慢 run 期间 submit 立即返回"的测试（假 streamFn 挂起）
5. AGENTS.md §4 不变量：单 active run、事件闭环不破
6. SubmitResult 语义变化需检查全部调用点（CLI/AppKit/eval）行为不退化

## 验证命令
- `swift test --filter Cli`；`swift test --filter Agent`
- 真机验收（Owner）：越界写 → picker 可见且 **↑↓/Enter/Esc 可操作** → 允许一次 → 文件创建成功
