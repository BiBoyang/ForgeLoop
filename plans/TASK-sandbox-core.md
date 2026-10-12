# TASK-sandbox-core：ForgeLoopSandbox 模块

- 状态：done
- 依赖：TASK-sandbox-spike（消费其 profile 模板与拒绝特征数据）
- 下游：TASK-sandbox-wire

## 目标
新增 `ForgeLoopSandbox` Swift 模块，提供数据化的权限策略与纯函数式的命令包装，对齐 Codex `sandboxing` crate 的两段式（策略 → transform）。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Package.swift`（注册新模块与测试 target）
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopSandbox/`：
  - `PermissionProfile.swift`：fs 维度 `readOnly / workspaceWrite(writableRoots) / fullAccess`；network 维度 `disabled / enabled`，注释预留 `.proxyWhitelist` 形状；整体 `Codable & Sendable`
  - `SeatbeltProfileRenderer.swift`：纯函数，PermissionProfile → `.sbpl` 文本；`(deny default)` 起手，可写根 `(allow file-write* (subpath ...))` 追加；路径需做 sbpl 转义
  - `SandboxTransform.swift`：纯函数，(command, args, PermissionProfile) → 包装后 argv（`/usr/bin/sandbox-exec -p <profile> ...`）；fullAccess 原样透传
  - `SandboxSupport.swift`：`/usr/bin/sandbox-exec` 存在性检测；macOS 之外明确报不支持
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopSandboxTests/`

## DoD
- 三档 profile 的渲染结果均有快照式断言（含 workspaceWrite 多可写根、路径含空格/引号的转义）
- transform 是纯函数、无 IO；单测风格对齐 Codex `manager_tests.rs` 的思路（输入 profile+命令 → 断言 argv）
- 遵循 AGENTS.md §5：无状态纯计算用 `Sendable struct`，不引入 actor
- `swift test --filter ForgeLoopSandbox` 全绿

## 验证命令
- `swift build` 与 `swift test --filter ForgeLoopSandbox`
