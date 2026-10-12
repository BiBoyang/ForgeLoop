# REVIEW-sandbox-spike-2026-10-12

## 结论
**Approved**

## 证据制核对
| 项 | 结果 | 证据 |
|---|---|---|
| 派发后验收标准零漂移 | Done | TASK/PROMPT 哈希与派发前记录一致 |
| status 过程记录 | Done | `prompts/TASK-sandbox-spike.status.md` 4 行，含失败-定位-修复轨迹 |
| 探针一条命令跑完矩阵 | Done | Reviewer 独立复跑 `swift Scripts/sandbox-spike/probe.swift` → PASS 10/10，PROBE_EXIT=0 |
| 拒绝特征清单（退出码+stderr 原文） | Done | 报告 §2：文件写=exit 1+`Operation not permitted`；网络=curl exit 6+`Could not resolve host`，含与宿主机抖动的区分 |
| base profile 模板 | Done | 报告 §3 全文，`(deny default)` 起手，可直接消费 |
| 范围纪律 | Done | git status 仅新增 Scripts/sandbox-spike/、notes/；Sources/、Tests/、Package.swift 零改动 |
| 现场干净 | Done | `$HOME` 无 sandbox-spike-denied 残留（拒绝真实生效），仓库无探针垃圾文件 |

## Findings
- [Minor] 报告 §2.3 的网络拒绝检测建议以 curl 文本为例；TASK-sandbox-approval 的启发式必须泛化（非 curl 进程的 DNS 失败文本不同），实现时以"文件类 EPERM 文本"为主锚点。不影响本任务验收。
- [Minor] 矩阵 #9 判据含"非拒绝特征也算过"的兜底（应对宿主机网络抖动），最终轮与 reviewer 复跑均抓到 exit=0 实证，可接受。

## 测试意见
探针自身即测试，三次独立运行（Executor 两轮 + Reviewer 一轮）结果一致。

## 残余风险
- `/var` firmlink 必须 `realpath(3)` 的约束已传递到下游 TASK-sandbox-core 的 PROMPT（writable root canonicalize 成为硬性验收项）。
- 父进程代理 env 污染问题，下游网络相关测试需继承"先 unset 代理"的纪律。

## 变更摘要
新增 `Scripts/sandbox-spike/probe.swift`（269 行）与 `notes/sandbox-spike-report.md`（141 行）；结论：seatbelt 通路可行，方案按原计划推进。
