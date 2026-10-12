# REVIEW-submit-nonblocking-2026-10-12

## 结论
**Approved**

## 证据制核对
| 项 | 结果 | 证据 |
|---|---|---|
| 验收标准零漂移 | Done | TASK/PROMPT 哈希与派发时一致 |
| status 过程记录 | Done | 4 行，含 SubmitResult 全部调用点核对记录 |
| Cli 测试 | Done | Reviewer 独立复跑 → 331/331（326+5 新用例） |
| Agent 测试 | Done | Reviewer 独立复跑 → 235/235 |
| 全套回归 | Done | Reviewer 独立复跑 `swift test` → 无失败，exit 0 |
| 范围纪律 | Done | 清单内文件 + 测试修正；`onRunStartupFailure` 未擅自接线清单外文件（正确克制） |

## 代码评审要点（diff 全读）
- `activeRunTask` 在 submit 返回前同步置位，关闭"Task 已 spawn 但 isStreaming 未置位"的 check-then-act 竞态——单 active run 不变量（§4）守得严实，这是最易错点。
- `Task{}` 继承 MainActor、生命周期归属 coordinator，非 detached——符合 §5 结构化并发。
- `alreadyRunning` 降级 steer 不丢用户输入——竞态兜底的正确姿势。
- 启动失败与运行期失败的分离记录清楚（onRunStartupFailure vs runLifecycle 事件流），语义边界干净。

## Findings
- [Minor] `onRunStartupFailure` 未在 TUI/AppKit 接线（Executor 克制未越界）；可达启动失败仅剩 hook 抛错且有 error 日志，可接受，后续按需要接线。
- [Minor] REVIEW-LOG 未更新（Executor 主动提出，不在清单内）——并入待提交的 docs 批次处理。
- [提示] run 结束到 activeRunTask 清理的微秒级窗口内提交会走 steer——语义一致、消息不丢，接受。

## 测试意见
5 个新用例直击要害（立即返回/run 中 steer/竞态窗口/失败事件可见/abort 后可再起），阻塞语义残留的旧测试修正而非删除。

## 残余风险
picker 真机可操作性待 Owner 终验——这是整条链的最后一步。

## 变更摘要
submit 非阻塞化（方案 B）；CLI/AppKit/eval 调用点核对无退化；+5 用例。输入侧结构性修复完成。
