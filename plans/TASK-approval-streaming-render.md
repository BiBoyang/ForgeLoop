# TASK-approval-streaming-render：审批 picker 在流式期间可见可交互

- 状态：done
- 依赖：无（沙箱审批链路已通，此为 UI 层收尾缺口）
- 上游证据：trace 实测 `sandbox_approval.request` 已触发但用户不可见；`CodingTUISession+Render.swift` streaming 分支 early-return 跳过 footer

## 目标
沙箱审批 picker 在 agent run 进行中（isStreaming）也能正常渲染与交互；审批结束后恢复流式渲染。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/CodingTUISession+Render.swift`（streaming 分支：activeApproval 非空时不走 early-return，渲染含 picker 的完整帧；审批结束回到 append 模式时处理 transcript 衔接，不重印不丢行）
- 必要时修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/CodingTUI.swift` 或 `CodingTUISession.swift`（如 append 模式状态切换需要）
- 测试：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopCliTests/` 下新增
- 保留 `sandbox_approval.request/resolved` 探针日志（已验证有用，转正）

## DoD
1. streaming 期间 activeApproval 非空 → picker 立即可见（帧含 picker 行）；按键（↑↓/Enter/Esc）有即时视觉反馈
2. 审批结束后 transcript 继续 append，不丢行、不重印（append 模式状态机正确退出/重入）
3. 非 streaming 期间的审批渲染行为不变（回归）
4. 有测试覆盖"streaming + activeApproval 的帧含 picker 内容"（可在 renderFrame/makeFooterRenderState 层加 seam，不强求端到端 TTY）
5. `swift test --filter Cli` 全绿；AGENTS.md §4 事件闭环不破

## 验证命令
- `swift test --filter Cli`
- 真机验收（Owner）：越界写指令 → picker 可见可操作 → 允许一次 → 文件创建成功
