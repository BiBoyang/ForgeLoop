---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-sandbox-core.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：ForgeLoopSandbox 模块（TASK-sandbox-core）

## 目标
新增 `ForgeLoopSandbox` Swift 模块：数据化 PermissionProfile + 纯函数式 seatbelt profile 渲染与 argv 包装。
成功标准：`swift build` 通过，`swift test --filter ForgeLoopSandbox` 全绿，渲染/包装逻辑零 IO 可单测。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Package.swift`（注册 `ForgeLoopSandbox` library target 与 `ForgeLoopSandboxTests`，不改动既有 target 的依赖关系）
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopSandbox/`
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopSandboxTests/`
- 不得改动 Sources/ 与 Tests/ 下的既有文件（集成是下游 TASK-sandbox-wire 的事）

## 验收标准（DoD）
1. `PermissionProfile`：`Codable & Sendable`；fs 维度 `readOnly / workspaceWrite(writableRoots: [URL]) / fullAccess`；network 维度 `disabled / enabled`（注释预留 `.proxyWhitelist` 形状）
2. `SeatbeltProfileRenderer`：纯函数 Profile → sbpl 文本；`(deny default)` 起手；**writableRoots 必须经 `realpath(3)` canonicalize**（`/var` firmlink 陷阱，上游实测 `resolvingSymlinksInPath` 无效）；base 骨架直接采用上游报告 §3 模板
3. `SandboxTransform`：纯函数 (command, args, profile) → 包装后 argv；`fullAccess` 原样透传；`/usr/bin/sandbox-exec` 绝对路径硬编码
4. `SandboxSupport`：`/usr/bin/sandbox-exec` 存在性检测；非 macOS 明确报不支持
5. 测试：三档渲染快照断言（含多可写根、路径含空格/引号转义、firmlink 路径 canonicalize 用 `/var` → `/private/var` 实测）；transform 输入输出断言；`swift test --filter ForgeLoopSandbox` 全绿
6. 遵循 AGENTS.md §5：无状态纯计算用 `Sendable struct`，禁止引入 actor / `@MainActor` 兜底

## 上游任务产出（TASK-sandbox-spike，已 Approved）
- 结论报告（base profile 模板在 §3，踩坑在 §4，必读）：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/sandbox-spike-report.md`
- 可运行参考实现：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Scripts/sandbox-spike/probe.swift`
- 关键约束：writable root 必须 `realpath(3)`；sbpl 子进程 stdout/stderr/exit code 原样透传（已实测）

## 参考实现（只读，不得修改）
- `/Users/boyang/Desktop/Agent 源码解读/codex 源码解读/codex-src/codex-rs/sandboxing/src/seatbelt.rs`
- `/Users/boyang/Desktop/Agent 源码解读/codex 源码解读/codex-src/codex-rs/sandboxing/src/manager.rs`（transform 单测风格参考 `manager_tests.rs`）

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-sandbox-core.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
