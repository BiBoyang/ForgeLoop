# Codex → ForgeLoop 沙箱移植笔记

- 日期：2026-10-12
- 参考实现（只读）：`/Users/boyang/Desktop/Agent 源码解读/codex 源码解读/codex-src/codex-rs/sandboxing/`（`seatbelt.rs`、`manager.rs`、`seatbelt_base_policy.sbpl` 等）
- 配套实证：`notes/sandbox-spike-report.md`（通路验证矩阵 + 拒绝特征 + 踩坑）
- 落地批次：TASK-sandbox-spike / core / wire / approval（四份 Review Card 见 `reviews/`，2026-10-12）

## 1. 概念映射表

| Codex（Rust） | ForgeLoop（Swift） | 说明 |
|---|---|---|
| `SandboxPolicy`（workspace-write 等枚举） | `PermissionProfile`（fs `readOnly/workspaceWrite/fullAccess` × network `disabled/enabled`） | 数据化策略，`Codable & Sendable`；网络维度预留 `.proxyWhitelist` 形状 |
| `SandboxManager` / policy → 命令 transform | `SandboxTransform.wrap(command:arguments:profile:)` | 纯函数 (command, args, profile) → argv；`fullAccess + enabled` 原样透传 |
| `MACOS_SEATBELT_BASE_POLICY` + 动态 param 拼接 | `SeatbeltProfileRenderer.render(_:)` | `(deny default)` 起手；base 骨架采用 spike 实测模板（codex base policy 的按需精简版） |
| `MACOS_PATH_TO_SEATBELT_EXECUTABLE = "/usr/bin/sandbox-exec"` | `SandboxTransform.sandboxExecPath` | 绝对路径硬编码，防 PATH 注入，逐字对齐 |
| `normalize_writable_root_for_sandbox`（canonicalize + 拒 symlink） | `SeatbeltProfileRenderer.canonicalize`（realpath）+ `SandboxProfileFactory.validateWritableRoots`（存在/目录/非 symlink/无控制字符） | 纯函数层只做 canonicalize 不抛错；策略校验在调用方（Review 移交职责划分） |
| `is_likely_sandbox_denied`（stderr 启发式） | `SandboxDenialHeuristic.isLikelySandboxDenial(exitCode:stderr:)` | 锚点收紧：非零退出 + `Operation not permitted`；curl exit 6 网络拒绝 v1 不触发 |
| `AskForApproval`（never/on-failure/...） | `ApprovalPolicy`（`never / onFailure`）+ `SandboxEscalationHandler`（`@Sendable` 闭包） | 两段式：启发式命中 → policy 判定 → handler 询问 → 批准非沙箱重跑一次（直调 `ProcessRunner(profile: nil)`，不递归） |
| 审批 UI（TUI ratatui 组件） | `CodingTUISession` 审批 picker（复用 ListPicker，`允许一次 / 拒绝`，默认落拒绝，Esc=拒绝） | 经 `SandboxApprovalBridge` 阻塞等待；仅交互式 TTY 注入 handler |
| writable root `-D` param 传参 | 直接字符串插值 + sbpl 转义（`\` `"`）+ factory 拒控制字符 | 简化实现；param 形式属防御纵深，缓做 |
| Landlock / bwrap（Linux 沙箱） | 不支持 | 项目 macOS-only |
| subagent 继承父沙箱语义 | `childConfig.sandboxProfile override ?? makeDefault(childCwd)` | **非字面透传**：父 `fullAccess` 不泄漏给子（fail-closed），对齐 Codex"对父的批准不构成对子的一般许可" |

## 2. 裁剪点（缓做/不做及一句话理由）

| Codex 组件 | 决定 | 理由 |
|---|---|---|
| Guardian（云端监护） | 缓做 | v1 目标是本地 seatbelt 通路；云端监护与本地沙箱正交，不影响本期安全边界 |
| network-proxy（`ManagedNetworkSandboxContext`，本地代理 + 白名单） | 缓做 | 默认断网已满足 workspace-write 语义；本地代理进程生命周期管理复杂度与收益不成比例 |
| execpolicy（Starlark 命令规则引擎） | 缓做（可能不做） | OS 沙箱取代了命令文本审计（`ShellCommandAuditor` 已删）；execpolicy 的残余价值是多命令拆分的细粒度授权，ROI 待观察 |
| seatbelt `-D` 参数化 profile | 缓做 | 字符串插值 + 转义 + 控制字符校验已覆盖注入面；param 化是防御纵深而非必需 |
| `(with report)` / unified log 违规归因 | 缓做 | v1 启发式锚点（EPERM 文本）已够驱动审批；更强归因见 spike 报告 §2.3 建议 |
| Landlock / bwrap / Windows（`windows.rs`） | 不做 | 仓库 platforms 仅 macOS 14+ |

## 3. 踩坑与出处（全部来自 spike 实测，勿凭直觉推翻）

1. **`/var` firmlink**：writable root 必须 `realpath(3)` canonicalize；`URL.resolvingSymlinksInPath` 实测无效（不解析 firmlink）。出处：`notes/sandbox-spike-report.md` §4.1。
2. **代理 env 透传污染**：父进程 `https_proxy` 等会进沙箱，网络开关测试必须先 unset。出处：§4.2。
3. **Pipe 并发读**：stdout/stderr 必须异步并发读，否则管道缓冲打满死锁；stdin 写完即 `closeFile()`。出处：§4.3。
4. **拒绝信号形态**：`-p` 模式 sandbox-exec 不写拒绝日志、不加前缀，退出码是子进程自己的；检测面向子进程 stderr 文本（文件类 `Operation not permitted`，网络类 curl exit 6 DNS 文本）。出处：§2。
5. **宿主机网络抖动 ≠ 沙箱拒绝**：exit 28/35 是网络问题，exit 6 + `Could not resolve host` 才是断网语义；集成测试因此豁免网络项（验证边界注记）。出处：§4.5。

## 4. 已知限制（随 v1 接受，Review 移交）

- 代码路径 abort 不会 resume 挂起的审批 continuation（用户 Esc 已覆盖）；如需更强语义，后续在 agent abort 时联动拒绝活跃审批。
- 网络断网语义端到端验证仅 spike 层证据（本机代理 env 污染，集成测试豁免）。
- subagent 内不接审批 handler（拒绝即失败），交互只发生在主 agent。
