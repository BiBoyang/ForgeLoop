# REVIEW-sandbox-wire-2026-10-12

## 结论
**Approved**（附 1 项需 Owner 裁决的已知缺口，见 Findings [Major]）

## 证据制核对
| 项 | 结果 | 证据 |
|---|---|---|
| 验收标准零漂移 | Done | TASK/PROMPT 哈希与派发前一致 |
| status 过程记录 | Done | 4 行，含 CodeSign 瞬时抖动记录 |
| Agent 测试 | Done | Reviewer 独立复跑 `--filter Agent` → 222/222 通过（含 SandboxIntegrationTests 13 用例） |
| 全套回归 | Done | Reviewer 独立复跑 `swift test` → 0 failure 套件行×88，无失败，exit 0 |
| 范围纪律 | Done | git status 仅任务书清单内文件 + status 文件；SessionCoordinator 未动（builder 默认构造已覆盖，理由成立） |
| auditor 移除 | Done | `grep ShellCommandAuditor` 代码零残留，仅 BashToolTests 一处历史说明注释（合理保留） |
| DoD 逐项 | Done | 管道执行/写 cwd/写 $HOME 拒绝/后台全覆盖/Factory 校验/配置口子（`CodingAgentConfig.sandboxProfile`）均已验证 |

## 代码评审要点（diff 全读）
- ProcessRunner 的"先定 exec 形态、再统一包装"结构正确，包装复杂度下沉，调用方只传 profile——符合 DoD 2 设计意图。
- SandboxProfileFactory 用 lstat 拒 symlink、拒控制字符、全拒降级 readOnly——Review 移交的两条 Minor 均已落实且有测试。
- `makeCodingAgent` 拒绝 root 经 diagnostics.log .warn 记录；CLI/App 全部调用点走默认 config，自动继承默认策略。
- firmlink 链路端到端实证：tempdir（/var/folders）经 Factory 校验 + renderer realpath 后写 cwd 成功。

## Findings
- **[Major，Executor 已披露，待 Owner 裁决]** `SubagentRunner.swift:88,97` 以 `BackgroundTaskManager()` / `BashTool(manager:)` 默认 `profile=nil` 构造——**subagent 的 bash 不经过沙箱**，是残留裸奔通道。不在本任务涉及文件清单内，Executor 未擅动（正确）。处置选项：
  a. 并入 Batch 4（TASK-sandbox-approval）PROMPT，SubagentRunner 加入涉及文件，把主 agent 的 profile 透传进 subagent（**推荐**：同一主题、批次未派发、改动约几行）
  b. 单独立 micro 任务，排在 Batch 4 前
  c. 接受裸奔（不推荐，与"不留裸奔通道"的既定目标冲突）
- [Minor] 网络项测试按 DoD 豁免（代理 env 污染），网络断网语义的端到端验证仍只有 spike 层证据；可接受，docs 任务应在移植笔记中注明该验证边界。

## 测试意见
13 个集成用例覆盖了任务书全部场景且断言对齐 spike 实测拒绝特征，质量达标；auditor 时期的 4 个注入拒绝用例正确改写为能力断言而非简单删除。

## 残余风险
subagent 裸奔通道在 Owner 裁决前仍然存在——在主 agent 全部命令都过沙箱的当下，模型可通过委派 subagent 绕过沙箱（多一步，但语义上成立）。

## 变更摘要
6 文件修改 + 1 测试文件新增；auditor 移除、全链路沙箱化、默认 workspaceWrite(cwd)+断网。全套回归无失败。
